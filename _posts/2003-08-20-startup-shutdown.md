---
layout: post
title: Startup, Shutdown and related matters
permalink: startup-shutdown
date: 2003-08-20 11:51:00.000000000 -07:00
status: publish
type: post
published: true
---

Usually I write blog articles on topics that people request via email or comments on other blogs.  Well, nobody has ever asked me to write anything about shutdown.

But then I look at all the problems that occur during process shutdown in the unmanaged world.  These problems occur because many people don’t understand the rules, or they don’t follow the rules, or the rules couldn’t possibly work anyway.

We’ve taken a somewhat different approach for managed applications.  But I don’t think we’ve ever explained in detail what that approach is, or how we expect well-written applications to survive an orderly shutdown.  Furthermore, managed applications still execute within an unmanaged OS process, so they are still subject to the OS rules.  And in V1 and V1.1 of the CLR we’ve horribly violated some of those OS rules related to startup and shutdown.  We’re trying to improve our behavior here, and I’ll discuss that too.

**Questionable APIs**

Unfortunately, I can’t discuss the model for shutting down managed applications without first discussing how unmanaged applications terminate.  And, as usual, I’ll go off on a bunch of wild tangents.

Ultimately, every OS process shuts down via a call to ExitProcess or TerminateProcess.  ExitProcess is the nice orderly shutdown, which notifies each DLL of the termination.  TerminateProcess is ruder, in that the DLLs are not informed.

The relationship between ExitProcess and TerminateProcess has a parallel in the thread routines ExitThread and TerminateThread.  ExitThread is the nice orderly thread termination, whereas if you ever call TerminateThread you may as well kill the process.  It’s almost guaranteed to be in a corrupt state.  For example, you may have terminated the thread while it holds the lock for the OS heap.  Any thread attempting to allocate or release memory from that same heap will now block forever.

Realistically, Win32 shouldn’t contain a TerminateThread service.  To a first approximation, anyone who has ever used this service has injected a giant bug into his application.  But it’s too late to remove it now.

In that sense, TerminateThread is like System.Threading.Thread.Suspend and Resume.  I cannot justify why I added those services.  The OS SuspendThread and ResumeThread are extremely valuable to a tiny subset of applications.  The CLR itself uses these routines to take control of threads for purposes like Garbage Collection and – as we’ll see later – for process shutdown.  As with TerminateThread, there’s a significant risk of leaving a thread suspended at a “bad” spot.  If you call SuspendThread while a thread is inside the OS heap lock, you better not try to allocate or free from that same heap.  In a similar fashion, if you call SuspendThread while a thread holds the OS loader lock (e.g. while the thread is executing inside DllMain) then you better not call LoadLibrary, GetProcAddress, GetModuleHandle, or any of the other OS services that require that same lock.

Even worse, if you call SuspendThread on a thread that is in the middle of exception dispatching inside the kernel, a subsequent GetThreadContext or SetThreadContext can actually produce a blend of the register state at the point of the suspension and the register state that was captured when the exception was triggered.  If we attempt to modify a thread’s context (perhaps bashing the EIP – on X86 – to redirect the thread’s execution to somewhere it will synchronize with the GC or other managed suspension), our update to EIP might quietly get lost.  Fortunately it’s possible to coordinate our user-mode exception dispatching with our suspension attempts in order to tolerate this race condition.

And probably the biggest gotcha with using the OS SuspendThread & ResumeThread services is on Win9X.  If a Win9X box contains real-mode device drivers (and yes, some of them still do), then it’s possible for the hardware interrupt associated with the device to interact poorly with the thread suspension.  Calls to GetThreadContext can deliver a register state that is perturbed by the real-mode exception processing.  The CLR installs a VxD on those operating systems to detect this case and retry the suspension.

Anyway, with sufficient care and discipline it’s possible to use the OS SuspendThread & ResumeThread to achieve some wonderful things.

But the managed Thread.Suspend & Resume are harder to justify.  They differ from the unmanaged equivalents in that they only ever suspend a thread at a spot inside managed code that is “safe for a garbage collection.”  In other words, we can report all the GC references at that spot and we can unwind the stack and register state to reveal our caller’s execution state.

Because we are at a place that’s safe for garbage collection, we can be sure that Thread.Suspend won’t leave a thread suspended while it holds an OS heap lock.  But it may be suspended while it holds a managed Monitor (‘lock’ in C# or ‘SyncLock’ in VB.NET).  Or it may be suspended while it is executing the class constructor (.cctor) of an important class like System.String.  And over time we intend to write more of the CLR in managed code, so we can enjoy all the benefits.  When that happens, a thread might be suspended while loading a class or resolving security policy for a shared assembly or generating shared VTables for COM Interop.

The real problem is that developers sometimes confuse Thread.Suspend with a synchronization primitive.  It is not.  If you want to synchronize two threads, you should use appropriate primitives like Monitor.Enter, Monitor.Wait, or WaitHandle.WaitOne.  Of course, it’s harder to use these primitives because you actually have to write code that’s executed by both threads so that they cooperate nicely.  And you have to eliminate the race conditions.

I’m already wandering miles away from Shutdown, and I need to get back.  But I can’t resist first mentioning that TerminateThread is distinctly different from the managed Thread.Abort service, both in terms of our aspirations and in terms of our current implementation.

Nobody should ever call TerminateThread.  Ever.

Today you can safely call Thread.Abort in two scenarios.

1. You can call Abort on your own thread (Thread.CurrentThread.Abort()).  This is not much different than throwing any exception on your thread, other than the undeniable manner in which the exception propagates.  The propagation is undeniable in the sense that your thread will continue to abort, even if you attempt to swallow the ThreadAbortException in a catch clause.  At the end-catch, the CLR notices that an abort is in progress and we re-throw the abort.  You must either explicitly call the ResetAbort method – which carries a security demand – or the exception must propagate completely out of all managed handlers, at which point we reset the undeniable nature of the abort and allow unmanaged code to (hopefully) swallow it.
2. An Abort is performed on all threads that have stack in an AppDomain that is being unloaded.  Since we are throwing away the AppDomain anyway, we can often tolerate surprising execution of threads at fairly arbitrary spots in their execution.  Even if this leaves managed locks unreleased and AppDomain statics in an inconsistent state, we’re throwing away all that state as part of the unload anyway.  This situation isn’t as robust as we would like it to be.  So we’re investing a lot of effort into improving our behavior as part of getting “squeaky clean” for highly available execution inside SQL Server in our next release.

Longer term, we’re committed to building enough reliability infrastructure around Thread.Abort that you can reasonably expect to use it to control threads that remain completely inside managed code.  Aborting threads that interleave managed and unmanaged execution in a rich way will always remain problematic, because we are limited in how much we can control the unmanaged portion of that execution.

**ExitProcess in a nutshell**

So what does the OS ExitProcess service actually do?  I’ve never read the source code.  But based on many hours of stress investigations, it seems to do the following:

1. Kill all the threads except one, whatever they are doing in user mode.  On NT-based operating systems, the surviving thread is the thread that called ExitProcess.  This becomes the shutdown thread.  On Win9X-based operating systems, the surviving thread is somewhat random.  I suspect that it’s the last thread to get around to committing suicide.
2. Once only one thread survives, no further threads can enter the process… almost.  On NT-based systems, I only see superfluous threads during shutdown if a debugger attaches to the process during this window.  On Win9X-based systems, any threads that were created during this early phase of shutdown are permitted to start up.  The DLL_THREAD_ATTACH notifications to DllMain for the starting threads will be arbitrarily interspersed with the DLL_PROCESS_DETACH notifications to DllMain for the ensuing shutdown.  As you might expect, this can cause crashes.
3. Since only one thread has survived (on the more robust NT-based operating systems), the OS now weakens all the CRITICAL_SECTIONs.  This is mixed blessing.  It means that the shutdown thread can allocate and free objects from the system heap without deadlocking.  And it means that application data structures protected by application CRITICAL_SECTIONs are accessible.  But it also means that the shutdown thread can see corrupt application state.  If one thread was wacked in step #1 above while it held a CRITICAL_SECTION and left shared data in an inconsistent state, the shutdown thread will see this inconsistency and must somehow tolerate it.  Also, data structures that are protected by synchronization primitives other than CRITICAL_SECTION are still prone to deadlock.
4. The OS calls the DllMain of each loaded DLL, giving it a DLL_PROCESS_DETACH notification.  The ‘lpReserved’ argument to DllMain indicates whether the DLL is being unloaded from a running process or whether the DLL is being unloaded as part of a process shutdown.  (In the case of the CLR’s DllMain, we only ever receive the latter style of notification.  Once we’re loaded into a process, we won’t be unloaded until the process goes away).
5. The process actually terminates, and the OS reclaims all the resources associated with the process.

Well, that sounds orderly enough.  But try running a multi-threaded process that calls ExitProcess from one thread and calling HeapAlloc / HeapFree in a loop from a second thread.  If you have a debugger attached, eventually you will trap with an ‘INT 3’ instruction in the OS heap code.  The OutputDebugString message will indicate that a block has been freed, but has not been added to the free list… It has been leaked.  That’s because the ExitProcess wacked your 2nd thread while it was in the middle of a HeapFree operation.

This is symptomatic of a larger problem.  If you wack threads while they are performing arbitrary processing, your application will be left in an arbitrary state.  When the DLL_PROCESS_DETACH notifications reach your DllMain, you must tolerate that arbitrary state.

I’ve been told by several OS developers that it is the application’s responsibility to take control of all the threads before calling ExitProcess.  That way, the application will be in a consistent state when DLL_PROCESS_DETACH notifications occur. If you work in the operating system, it’s reasonable to consider the “application” to be a monolithic homogenous piece of code written by a single author.  So of course that author should put his house in order and know what all the threads are doing before calling ExitProcess.

But if you work on an application, you know that there are always multiple components written by multiple authors from different vendors.  These components are only loosely aware of each other’s implementations – which is how it should be.  And some of these components have extra threads on the side, or they are performing background processing via IOCompletion ports, threadpools, or other techniques.

Under those conditions, nobody can have the global knowledge and global control necessary to call ExitProcess “safely”.  So, regardless of the official rules, ExitProcess will be called while various threads are performing arbitrary processing.

**The OS Loader Lock**

It’s impossible to discuss the Win32 model for shutting down a process without considering the OS loader lock.  This is a lock that is present on all Windows operating systems.  It provides mutual exclusion during loading and unloading.

Unfortunately, this lock is held while application code executes.  This fact alone is sufficient to guarantee disaster.

If you can avoid it, you must never hold one of your own locks while calling into someone else’s code.  They will screw you every time.

Like all good rules, this one is made to be broken.  The CLR violates this rule in a few places.  For example, we hold a ‘class constructor’ lock for your class when we call your .cctor method.  However, the CLR recognizes that this fact can lead to deadlocks and other problems.  So we have rules for weakening this lock when we discover cycles of .cctor locks in the application, even if these cycles are distributed over multiple threads in multi-threaded scenarios.  And we can see through various other locks, like the locks that coordinate JITting, so that larger cycles can be detected.  However, we deliberately don’t look through user locks (though we could see through many of these, like Monitors, if we chose).  Once we discover a visible, breakable lock, we allow one thread in the cycle to see uninitialized state of one of the classes.  This allows forward progress and the application continues.  See my earlier blog on “Initializing code” for more details.

Incidentally, I find it disturbing that there’s often little discipline in how managed locks like Monitors are used.  These locks are so convenient, particularly when exposed with language constructs like C# lock and VB.NET SyncLock (which handle backing out of the lock during exceptions), that many developers ignore good hygiene when using them.  For example, if code uses multiple locks then these locks should typically be ranked so that they are always acquired in a predictable order.  This is one common technique for avoiding deadlocks.

Anyway, back to the loader lock.  The OS takes this lock implicitly when it is executing inside APIs like GetProcAddress, GetModuleHandle and GetModuleFileName.  By holding this lock inside these APIs, the OS ensures that DLLs are not loading and unloading while it is groveling through whatever tables it uses to record the state of the process.

So if you call those APIs, you are implicitly acquiring a lock.

That same lock is also acquired during a LoadLibrary, FreeLibrary, or CreateThread call.  And – while it is held – the operating system will call your DllMain routine with a notification.  The notifications you might see are:

*DLL_THREAD_ATTACH*. The thread that calls your DllMain has just been injected into the process.  If you need to eagerly allocate any TLS state, this is your opportunity to do so.  In the managed world, it is preferable to allocate TLS state lazily on the first TLS access on a given thread.

*DLL_THREAD_DETACH*. The thread that calls your DllMain has finished executing the thread procedure that it was started up with.  After it finishes notifying all the DLLs of its death in this manner, it will terminate.  Many unmanaged applications use this notification to de-allocate their TLS data.  In the managed world, managed TLS is automatically cleaned up without your intervention.  This happens as a natural consequence of garbage collection.

*DLL_PROCESS_ATTACH*. The thread that calls your DllMain is loading your DLL via an explicit LoadLibraryEx call or similar technique, like a static bind.  The lpReserved argument indicates whether a dynamic or static bind is in progress.  This is your opportunity to initialize any global state that could not be burned into the image.  For example, C++ static initializers execute at this time.  The managed equivalent has traditionally been a class constructor method, which executes once per AppDomain.  In a future version of the CLR, we hope to provde a more convenient module constructor concept.

*DLL_PROCESS_DETACH*. If the process is terminating in an orderly fashion (ExitProcess), your DllMain will receive a DLL_PROCESS_DETACH notification where the lpReserved argument is non-null.  If the process is terminating in a rude fashion (TerminateProcess), your DllMain will receive no notification.  If someone unloads your DLL via a call to FreeLibrary or equivalent, the process will continue executing after you unload.  This case is indicated by a null value for lpReserved.  In the managed world, de-initialization happens through notifications of AppDomain unload or process exit, or through finalization activity.

The DLL_THREAD_ATTACH and DLL_THREAD_DETACH calls have a performance implication.  If you have loaded 100 DLLs into your process and you start a new thread, that thread must call 100 different DllMain routines.  Let’s say that these routines touch a page or two of code each, and a page of data.  That might be 250 pages (1 MB) in your working set, for no good reason.
The CLR calls DisableThreadLibraryCalls on all managed assemblies other than certain MC++ IJW assemblies (more on this later) to avoid this overhead for you.  And it’s a good idea to do the same on your unmanaged DLLs if they don’t need these notifications to manage their TLS.

Writing code inside DllMain is one of the most dangerous places to write code.  This is because you are executing inside a callback from the OS loader, inside the OS loader lock.

Here are some of the rules related to code inside DllMain:

1. You must never call LoadLibrary or otherwise perform a dynamic bind.
2. You must never attempt to acquire a lock, if that lock might be held by a thread that needs the OS loader lock.  (Acquiring a heap lock by calling HeapAlloc or HeapFree is probably okay).
3. You should never call into another DLL.  The danger is that the other DLL may not have initialized yet, or it may have already uninitialized.  (Calling into kernel32.dll is probably okay).
4. You should never start up a thread or terminate a thread, and then rendezvous with that other thread’s start or termination.

As we shall see, the CLR violates some of these rules.  And these violations have resulted in serious consequences for managed applications – particularly managed applications written in MC++.

And if you’ve ever written code inside DllMain – including code that’s implicitly inside DllMain like C++ static initializers or ‘atexit’ routines – then you’ve probably violated some of these rules.  Rule #3 is especially harsh.

The fact is, programs violate these rules all the time and get away with it.  Knowing this, the MC++ and CLR teams made a bet that they could violate some of these rules when executing IJW assemblies.  It turns out that we bet wrong.

I’m going to explain exactly how we screwed this up with IJW assemblies, but first I need to explain what IJW assemblies are.

**IJW**

IJW is how we internally refer to mixed managed / unmanaged images.  If you compile a MC++ assembly with ‘/clr’ in V1 or V1.1, it almost certainly contains a mixture of managed and unmanaged constructs.

In future versions, I expect there will be ways to compile MC++ assemblies with compiler-enforced guarantees that the image is guaranteed pure managed, or guaranteed pure verifiable managed, or – ultimately – perhaps even pure verifiable 32-bit / 64-bit neutral managed.  In each case, the compiler will necessarily have to restrict you to smaller and smaller subsets of the C++ language.  For example, verifiable C++ cannot use arbitrary unmanaged pointers.  Instead, it must restrict itself to managed pointers and references, which are reported to the garbage collector and which follow certain strict rules.  Furthermore, 32-bit / 64-bit neutral code cannot consume the declarations strewn through the windows.h headers, because these pick a word size during compilation.

IJW is an acronym for “It Just Works” and it reflects the shared goal of the C++ and CLR teams to transparently compile existing arbitrary C++ programs into IL.  I think we did an amazing job of approaching that goal, but of course not everything “just works.”  First, there are a number of constructs like inline assembly language that cannot be converted to managed execution.  The C++ compiler, linker and CLR ensure that these methods are left as unmanaged and that managed callers transparently switch back to unmanaged before calling them.

So inline X86 assembly language must necessarily remain in unmanaged code.  Some other constructs are currently left in unmanaged code, though with sufficient effort we could provide managed equivalents.  These other constructs include setjmp / longjmp, member pointers (like pointer to virtual method), and a reasonable startup / shutdown story (which is what this blog article is supposed to be about).

I’m not sure if we ever documented the constructs that are legal in a pure managed assembly, vs. those constructs which indicate that the assembly is IJW.  Certainly we have a strict definition of this distinction embedded in our code, because the managed loader considers it when loading.  Some of the things we consider are:

A pure managed assembly has exactly one DLL import.  This import is to mscoree.dll’s _CorExeMain (for an EXE) or _CorDllMain (for a DLL).  The entrypoint of the EXE or DLL must be a JMP to this import.  This is how we force the runtime to load and get control whenever a managed assembly is loaded.

A pure managed assembly can have no DLL exports.  When we bind to pure managed assemblies, it is always through managed Fusion services, via AssemblyRefs and assembly identities (ideally with cryptographic strong names).

A pure managed assembly has exactly one rebasing fixup.  This fixup is for the JMP through the import table that I mentioned above.  Unmanaged EXEs tend to strip all their rebasing fixups, since EXEs are almost guaranteed to load at their preferred addresses.  However, managed EXEs can be loaded like DLLs into a running process.  That single fixup is useful for cases where we want to load via LoadLibraryEx on versions of the operating system that support this.

A pure managed assembly has no TLS section and no other exotic constructs that are legal in arbitrary unmanaged PE files.

Of course, IJW assemblies can have many imports, exports, fixups, and other constructs.  As with pure managed assemblies, the entrypoint is constrained to be a JMP to mscoree.dll’s _CorExeMain or _CorDllMain function.  This is the “outer entrypoint”.  However, the COM+ header of the PE file has an optional “inner entrypoint”.  Once the CLR has proceeded far enough into the loading process on a DLL, it will dispatch to this inner entrypoint which is… your normal DllMain.  In V1 and V1.1, this inner entrypoint is expressed as a token to a managed function.  Even if your DllMain is written as an unmanaged function, we dispatch to a managed function which is defined as a PInvoke out to the unmanaged function.

Now we can look at the set of rules for what you can do in a DllMain, and compare it to what the CLR does when it sees an IJW assembly.  The results aren’t pretty.  Remember that inside DllMain:

*<ins>You must never call LoadLibrary or otherwise perform a dynamic bind</ins>*

With normal managed assemblies, this isn’t a concern.  For example, most pure managed assemblies are loaded through Assembly.Load or resolution of an AssemblyRef – outside of the OS loader lock.  Even activation of a managed COM object through OLE32’s CoCreateInstance will sidestep this issue.  The registry entries for the CLSID always mention mscoree.dll as the server.  A subkey is consulted by mscoree.dll – inside DllGetClassObject and outside of the OS loader lock – to determine which version of the runtime to spin up and which assembly to load.

But IJW assemblies have arbitrary DLL exports.  Therefore other DLLs, whether unmanaged or themselves IJW, can have static or dynamic (GetProcAddress) dependencies on an IJW assembly.  When the OS loads the IJW assembly inside the loader lock, the OS further resolves the static dependency from the IJW assembly to mscoree.dll’s _CorDllMain.  Inside _CorDllMain, we must select an appropriate version of the CLR to initialize in the process.  This involves calling LoadLibrary on a particular version of mscorwks.dll, violating our first rule for DllMain.

So what goes wrong when this rule is violated?  Well, the OS loader has already processed all the DLLs and their imports, walking the tree of static dependencies and forming a loading plan.  It is now executing on this plan.  Let’s say that the loader’s plan is to first initialize an IJW assembly, then initialize its dependent mscoree.dll reference, and then initialize advapi32.dll.  (By ‘initialize’, I mean give that DLL its DLL_PROCESS_ATTACH notification).  When mscoree.dll decides to LoadLibrary mscorwks.dll, a new loader plan must be created.  If mscorwks.dll depends on advapi32.dll (and of course it does), we have a problem.  The OS loader already has advapi32.dll on its pending list.  It will initialize that DLL when it gets far enough into its original loading plan, but not before.

If mscorwks.dll needs to call some APIs inside advapi32.dll, it will now be making those calls before advapi32.dll’s DllMain has been called.  This can and does lead to arbitrary failures.  I personally hear about problems with this every 6 months or so.  That’s a pretty low rate of failure.  But one of those failures was triggered when a healthy application running on V1 of the CLR was moved to V1.1 of the CLR.  Ouch.

*<ins>You must never attempt to acquire a lock, if that lock might be held by a thread that needs the OS loader lock</ins>*

It’s not possible to execute managed code without potentially acquiring locks on your thread.  For example, we may need to initialize a class that you need access to.  If that class isn’t already initialized in your AppDomain, we will use a .cctor lock to coordinate initialization.  Along the same lines, if a method requires JIT compilation we will use a lock to coordinate this.  And if your thread allocates a managed object, it may have to take a lock.  (We don’t take a lock on each allocation if we are executing on a multi-processor machine, for obvious reasons.  But eventually your thread must coordinate with the garbage collector via a lock before it can proceed with more allocations).

So if you execute managed code inside the OS loader lock, you are going to contend for a CLR lock.  Now consider what happens if the CLR ever calls GetModuleHandle or GetProcAddress or GetModuleFileName while it holds one of those other locks.  This includes implicit calls to LoadLibrary / GetProcAddress as we fault in any lazy DLL imports from the CLR.

Unfortunately, the sequence of lock acquisition is inverted on the two threads.  This yields a classic deadlock.

Once again, this isn’t a concern for pure managed assemblies.  The only way a pure managed assembly can execute managed code inside the OS loader lock is if some unmanaged code explicitly calls into it via a marshaled out delegate or via a COM call from its own DllMain.  That’s a bug in the unmanaged code!  But with an IJW assembly, some methods are managed and some are unmanaged.  The compiler, linker and CLR conspire to make this fact as transparent as possible.  But any call from your DllMain (i.e. from your inner entrypoint) to a method that happened to be emitted as IL will set you up for this deadlock.

*<ins>You should never call into another DLL</ins>*

It’s really not possible to execute managed code without making cross-DLL calls.  The JIT compiler is in a different DLL from the ExecutionEngine.  The ExecutionEngine is in a different DLL from your IJW assembly.

Once again, pure managed assemblies don’t usually have a problem here.  I did run into one case where one of the Microsoft language compilers was doing a LoadLibrary of mscorlib.dll.  This had the side effect of spinning up the CLR inside the OS loader lock and inflicting all the usual IJW problems onto the compilation process.  Since managed assemblies have no DLL exports, it’s rare for applications to load them in this manner.  In the case of this language compiler, it was doing so for the obscure purpose of printing a banner to the console at the start of compilation, telling the user what version of the CLR it was bound to.  There are much better ways of doing this sort of thing, and none of those other ways would interfere with the loader lock.  This has been corrected.

*<ins>You should never start up a thread or terminate a thread, and then rendezvous</ins>*

This probably doesn’t sound like something you would do.  And yet it’s one of the most common deadlocks I see with IJW assemblies on V1 and V1.1 of the CLR.  The typical stack trace contains a load of an IJW assembly, usually via a DLL import.  This causes mscoree.dll’s _CorDllMain to get control.  Eventually, we notice that the IJW assembly has been strong name signed, so we call into WinVerifyTrust in WinTrust.dll.  That API has a perfectly reasonable expectation that it is not inside the OS loader lock.  It calls into the OS threadpool (not the managed CLR threadpool), which causes the OS threadpool to lazily initialize itself.  Lazy initialization involves spinning up a waiter thread, and then blocking until that waiter thread starts executing.

Of course, the new waiter thread must first deliver DLL_THREAD_ATTACH notifications to any DLLs that expect such notifications.  And it must obviously obtain the OS loader lock before it can deliver the first notification.  The result is a deadlock.

So I’ve painted a pretty bleak picture of all the things that can go wrong with IJW assemblies in V1 and V1.1 of the CLR.  If we had seen a disturbing rate of failures prior to shipping V1, we would have reconsidered our position here.  But it wasn’t until later that we had enough external customers running into these difficulties.  With the benefits of perfect hindsight, it is now clear that we screwed up.

Fortunately, much of this is fixable in our next release.  Until then, there are some painful workarounds that might bring you some relief.  Let’s look at the ultimate solution first, and then you can see how the workarounds compare.  We think that the ultimate solution would consist of several parts:

Just loading an IJW assembly must not spin up a version of the CLR.  That’s because spinning up a version of the CLR necessarily involves a dynamic load, and we’ve seen that dynamic loads are illegal during loading and initializing of static DLL dependencies.  Instead, mscoree.dll must perform enough initialization of the IJW assembly without actually setting up a full runtime.  This means that all calls into the managed portion of the IJW assembly must be bashed so that they lazily load a CLR and initialize it on first call.

Along the same lines, the inner entrypoint of an IJW assembly must either be omitted or must be encoded as an unmanaged entrypoint.  Recall that the current file format doesn’t have a way of representing unmanaged inner entrypoints, since this is always in the form of a token.  Even if the token refers to an unmanaged method, we would have to spin up a version of the CLR to interpret that token for us.  So we’re going to need a tweak to the current file format to enable unmanaged inner entrypoints.

An unmanaged inner entrypoint is still a major risk.  If that inner entrypoint calls into managed code, we will trap the call and lazily spin up the correction version of the CLR.  At that point, you are in exactly the same situation as if we had left the entrypoint as managed.  Ideally, assembly-level initialization and uninitialization would never happen inside the OS loader lock.  Instead, they would be replaced with modern managed analogs that are unrelated to the unmanaged OS loader’s legacy behavior.  If you read my old blog on “Initializing code” at http://cbrumme.dev/initializing-code, I mention that we’re under some pressure to add a module-level equivalent of .cctor methods.  That mechanism would make a great replacement for traditional DLL_PROCESS_ATTACH notifications.  In fact, the CLR has always supported a .cctor method at a global module scope.  However, the semantics associated with such a method was that it ran before any access to static members at global module scope.  A more useful semantic for a future version of the CLR would be for such a global .cctor to execute before any access to members in the containing Module, whether global or contained in any of the Module’s types.

The above changes make it possible to avoid execution of managed code inside the OS loader lock.  But it’s still possible for a naïve or misbehaved unmanaged application to call a managed service (like a marshaled out delegate or a managed COM object) from inside DllMain.  This final scenario is not specific to IJW.  All managed execution is at risk to this kind of abuse.  Ideally, the CLR would be able to detect attempts to enter it while the loader lock is held, and fail these attempts.  It’s not clear whether such detection / prevention should be unconditional or whether it should be enabled through a Customer Debug Probe.

If you don’t know what Customer Debug Probes are, please hunt them down on MSDN.  They are a life-saver for debugging certain difficult problems in managed applications.  I would recommend starting with http://www.gotdotnet.com/Community/UserSamples/Details.aspx?SampleGuid=c7b955c7-231a-406c-9fa5-ad09ef3bb37f, and then reading most of Adam Nathan’s excellent blogs at http://blogs.gotdotnet.com/anathan.

Of the above 4 changes, we’re relatively confident that the first 3 will happen in the next release.  We also experimented with the 4th change, but it’s unlikely that we will make much further progress.  A key obstacle is that there is no OS-approved way that can efficiently detect execution inside the loader lock.  Our hope is that a future version of the OS would provide such a mechanism.

This is all great.  But you have an application that must run on V1 or V1.1.  What options do you have?  Fortunately, Scott Currie has written an excellent article on this very subject.  If you build IJW assemblies, please read it at http://msdn.microsoft.com/library/default.asp?url=/library/en-us/dv_vstechart/html/vcconmixeddllloadingproblem.asp.

**The Pure Managed Story**

If you code in a language other than MC++, you’re saying “Enough about IJW and the OS loader lock already.”

Let’s look at what the CLR does during process shutdown.  I’ll try not to mention IJW, but I’ll have to keep talking about that darn loader lock.

From the point of view of a managed application, there are three types of shutdown:

1. A shutdown initiated by a call to TerminateProcess doesn’t involve any further execution of the CLR or managed code.  From our perspective, the process simply disappears.  This is the rudest of all shutdowns, and neither the CLR developer nor the managed developer has any obligations related to it.
2. A shutdown initiated by a direct call to ExitProcess is an unorderly shutdown from the point of view of the managed application.  Our first notification of the shutdown is via a DLL_PROCESS_DETACH notification.  This notification could first be delivered to the DllMain of mscorwks.dll, mscoree.dll, or any of the managed assemblies that are currently loaded.  Regardless of which module gets the notification first, it is always delivered inside the OS loader lock.  It is not safe to execute any managed code at this time.  So the CLR performs a few house-keeping activities and then returns from its DllMain as quickly as possible.  Since no managed code runs, the managed developer still has no obligations for this type of shutdown.
3. An orderly managed shutdown gives managed code an opportunity to execute outside of the OS loader lock, prior to calling ExitProcess.  There are several ways we can encounter an orderly shutdown.  Because we will execute managed code, including Finalize methods, the managed developer must consider this case.

Examples of an orderly managed shutdown include:

1. Call System.Environment.Exit().  I already mentioned that some Windows developers have noted that you must not call ExitProcess unless you first coordinate all your threads… and then they work like mad to make the uncoordinated case work.  For Environment.Exit we are under no illusions.  We expect you to call it in races from multiple threads at arbitrary times.  It’s our job to somehow make this work.
2. If a process is launched with a managed EXE, then the CLR tracks the number of foreground vs. background managed threads.  (See Thread.IsBackground).  When the number of foreground threads drops to zero, the CLR performs an orderly shutdown of the process.  Note that the distinction between foreground and background threads serves exactly this purpose and no other purpose.
3. Starting with MSVCRT 7.0, an explicit call to ‘exit()’ or an implicit call to ‘exit()’ due to a return from ‘main()’ can turn into an orderly managed shutdown.  The CRT checks to see if mscorwks.dll or mscoree.dll is in the process (I forget which).  If it is resident, then it calls CorExitProcess to perform an orderly shutdown.  Prior to 7.0, the CRT is of course unaware of the CLR.
4. Some unmanaged applications are aware of the CLR’s requirements for an orderly shutdown.  An example is devenv.exe, which is the EXE for Microsoft Visual Studio.  Starting with version 7, devenv calls CoEEShutDownCOM to force all the CLR’s references on COM objects to be Release()’d.  This at least handles part of the managed shutdown in an orderly fashion.  It’s been a while since I’ve looked at that code, but I think that ultimately devenv triggers an orderly managed shutdown through a 2nd API.

If you are following along with the Rotor sources, this all leads to an interesting quirk of EEShutDown in ceemain.cpp.  That method can be called:

* 0 times, if someone calls TerminateProcess.
* 1 time, if someone initiates an unorderly shutdown via ExitProcess.
* 2 times, if we have a single-threaded orderly shutdown.  In this case, the first call is made outside of the OS loader lock.  Later, we call ExitProcess for the 2nd half of the shutdown.  This causes EEShutDown to be called a 2nd time.
* Even more times, if we have a multi-threaded orderly shutdown.  Many threads will race to call EEShutDown the first time, outside the OS loader lock.  This routine protects itself by anointing a winner to proceed with the shutdown.  Then the eventual call to ExitProcess causes the OS to kill all threads except one, which calls back to EEShutDown inside the OS loader lock.

Of course, our passage through EEShutDown is quite different when we are outside the OS loader lock, compared to when we are inside it.  When we are outside, we do something like this

* First we synchronize at the top of EEShutDown, to handle the case where multiple threads race via calls to Environment.Exit or some equivalent entrypoint.
* Then we finalize all objects that are unreachable.  This finalization sweep is absolutely normal and occurs while the rest of the application is still running.
* Then we signal for the finalizer thread to finish its normal activity and participate in the shutdown.  The first thing it does is raise the AppDomain.ProcessExit event.  Once we get past this point, the system is no longer behaving normally.  You could either listen to this event, or you could poll System.Environment.HasShutdownStarted to discover this fact.  This can be an important fact to discover in your Finalize method, because it’s more difficult to write robust finalization code when we have started finalizing reachable objects.  It’s no longer possible to depend on WaitHandles like Events, remoting infrastructure, or other objects.  The other time we can finalize reachable objects is during an AppDomain unload.  This case can be discovered by listening to the AppDomain.DomainUnload event or by polling for the AppDomain.IsFinalizingForUnload state.  The other nasty thing to keep in mind is that you can only successfully listen to the ProcessExit event from the Default AppDomain.  This is something of a bug and I think we would like to try fixing it for the next release.
* Before we can start finalizing reachable objects, we suspend all managed activity.  This is a suspension from which we will never resume.  Our goal is to minimize the number of threads that are surprised by the finalization of reachable state, like static fields, and it’s similar to how we prevent entry to a doomed AppDomain when we are unloading it.
* This suspension is unusual in that we allow the finalizer thread to bypass the suspension.  Also, we change suspended threads that are in STAs, so that they pump COM messages.  We would never do this during a garbage collection, since the reentrancy would be catastrophic.  (Threads are suspended for a GC at pretty arbitrary places… down to an arbitrary machine code instruction boundary in many typical scenarios).  But since we are never going to resume from this suspension, and since we don’t want cross-apartment COM activity to deadlock the shutdown attempt, pumping makes sense here.  This suspension is also unusual in how we raise the barrier against managed execution.  For normal GC suspensions, threads attempting to call from unmanaged to managed code would block until the GC completes.  In the case of a shutdown, this could cause deadlocks when it is combined with cross-thread causality (like synchronous cross-apartment calls).  Therefore the barrier behaves differently during shutdown.  Returns into managed code block normally.  But calls into managed code are failed.  If the call-in attempt is on an HRESULT plan, we return an HRESULT.  If it is on an exception plan, we throw.  The exception code we raise is 0xC0020001 and the argument to RaiseException is a failure HRESULT formed from the ERROR_PROCESS_ABORTED SCODE (0x1067).
* Once all objects have been finalized, even if they are reachable, then we Release() all the COM pUnks that we are holding.  Normally, releasing a chain of pUnks from a traced environment like the CLR involves multiple garbage collections.  Each collection discovers a pUnk in the chain and subsequently Release’s it.  If that Release on the unmanaged side is the final release, then the unmanaged pUnk will be free’d.  If that pUnk contains references to managed objects, those references will now be dropped.  A subsequent GC may now collect this managed object and the cycle begins again.  So a chain of pUnks that interleaves managed and unmanaged execution can require a GC for each interleaving before the entire chain is recovered.  During shutdown, we bypass all this.  Just as we finalize objects that are reachable, we also drop all references to unmanaged pUnks, even if they are reachable.

From the perspective of managed code, at this point we are finished with the shutdown, though of course we perform many more steps for the unmanaged part of the shutdown.

There are a couple of points to note with the above steps.

1. We never unwind threads.  Every so often developers express their surprise that ‘catch’, ‘fault’, ‘filter’ and ‘finally’ clauses haven’t executed throughout all their threads as part of a shutdown.  But we would be nuts to try this.  It’s just too disruptive to throw exceptions through threads to unwind them, unless we have a compelling reason to do so (like AppDomain.Unload).  And if those threads contain unmanaged execution on their threads, the likelihood of success is even lower.  If we were on that plan, some small percentage of attempted shutdowns would end up with “Unhandled Exception / Debugger Attach” dialogs, for no good reason.

2. Along the same lines, developers sometimes express their surprise that all the AppDomains aren’t unloaded before the process exits.  Once again, the benefits don’t justify the risk or the overhead of taking these extra steps.  If you have termination code you must run, the ProcessExit event and Finalizable objects should be sufficient for doing so.

3. We run most of the above shutdown under the protection of a watchdog thread.  By this I mean that the shutdown thread signals the finalizer thread to perform most of the above steps.  Then the shutdown thread enters a wait with a timeout.  If the timeout triggers before the finalizer thread has completed the next stage of the managed shutdown, the shutdown thread wakes up and skips the rest of the managed part of the shutdown.  It does this by calling ExitProcess.  This is almost fool-proof.  Unfortunately, if the shutdown thread is an STA thread it will pump COM messages (and SendMessages), while it is performing this watchdog blocking operation.  If it picks up a COM call into its STA that deadlocks, then the process will hang.  In a future release, we can fix this by using an extra thread.  We’ve hesitated to do so in the past because the deadlock is exceedingly rare, and because it’s so wasteful to burn a thread in this manner.

Finally, a lot more happens inside EEShutDown than the orderly managed steps listed above.  We have some unmanaged shutdown that doesn’t directly impact managed execution.  Even here we try hard to limit how much we do, particularly if we’re inside the OS loader lock.  If we must shutdown inside the OS loader lock, we mostly just flush any logs we are writing and detach from trusted services like the profiler or debugger.

One thing we do not do during shutdown is any form of leak detection.  This is somewhat controversial.  There are a number of project teams at Microsoft which require a clean leak detection run whenever they shutdown.  And that sort of approach to leak detection has been formalized in services like MSVCRT’s _CrtDumpMemoryLeaks, for external use.  The basic idea is that if you can find what you have allocated and release it, then you never really leaked it.  Conversely, if you cannot release it by the time you return from your DllMain then it’s a leak.

I’m not a big fan of that approach to finding memory leaks, for a number of reasons:

* The fact that you can reclaim memory doesn’t mean that you were productively using it.  For example, the CLR makes extensive use of “loader heaps” that grow without release until an AppDomain unloads.  At that point, we discard the entire heap without regard for the fine-grained allocations within it.  The fact that we remembered where all the heaps are doesn’t really say anything about whether we leaked individual allocations within those heaps.
* In a few well-bounded cases, we intentionally leak.  For example, we often build little snippets of machine code dynamically.  These snippets are used to glue together pieces of JITted code, or to check security, or twiddle the calling convention, or various other reasons.  If the circumstances of creation are rare enough, we might not even synchronize threads that are building these snippets.  Instead, we might use a light-weight atomic compare/exchange instruction to install the snippet.  Losing the race means we must discard the extra snippet.  But if the snippet is small enough, the race is unlikely enough, and the leak is bounded enough (e.g. we only need one such snippet per AppDomain or process and reclaim it when the AppDomain or process terminates), then leaking is perfectly reasonable.  In that case, we may have allocated the snippet in a heap that doesn’t support free’ing.
* This approach certainly encourages a lot of messy code inside the DLL_PROCESS_DETACH notification – which we all know is a very dangerous place to write code.  This is particularly true, given the way threads are wacked by the OS at arbitrary points of execution.  Sure, all the OS CRITICAL_SECTIONs have been weakened.  But all the other synchronization primitives are still owned by those wacked threads.  And the weakened OS critical sections were supposed to protect data structures that are now in an inconsistent state.  If your shutdown code wades into this landmine of deadlocks and trashed state, it will have a hard time cleanly releasing memory blocks.  Projects often deal with this case by keeping a count of all locks that are held.  If this count is non-zero when we get our DLL_PROCESS_DETACH notification, it isn’t safe to perform leak detection.  But this leads to concerns about how often the leak detection code is actually executed.  For a while, we considered it a test case failure if we shut down a process while holding a lock.  But that was an insane requirement that was often violated in race conditions.
* The OS is about to reclaim all resources associated with this process.  The OS will perform a faster and more perfect job of this than the application ever could.  From a product perspective, leak detection at product shutdown is about the least interesting time to discover leaks.
* DLL_PROCESS_DETACH notifications are delivered to different DLLs in a rather arbitrary order.  I’ve seen DLLs either depend on brittle ordering, or I’ve seen them make cross-DLL calls out of their DllMain in an attempt to gain control over this ordering.  This is all bad practice.  However, I must admit that in V1 of the CLR, fusion.dll & mscorwks.dll played this “dance of death” to coordinate their termination.  Today, we’ve moved the Fusion code into mscorwks.dll.
* I think it’s too easy for developers to confuse all the discipline surrounding this approach with actually being leak-free.  The approach is so onerous that the goal quickly turns into satisfying the requirements rather than chasing leaks.

There are at least two other ways to track leaks.

One way is to identify scenarios that can be repeated, and then monitor for leaks during the steady-state of repeating those scenarios.  For example, we have a test harness which can create an AppDomain, load an application into it, run it, unload the AppDomain, then rinse and repeat.  The first few times that we cycle through this operation, memory consumption increases.  That’s because we actually JIT code and allocate data structures to support creating a 2nd AppDomain, or support making remote calls into the 2nd AppDomain, or support unloading that AppDomain.  More subtly, the ThreadPool might create – and retain – a waiter thread or an IO thread.  Or the application may trigger the creation of a new segment in the GC heap which the GC decides to retain even after the incremental contents have become garbage.  This might happen because the GC decides it is not productive to perform a compacting collection at this time.  Even the OS heap can make decisions about thread-relative look-aside lists or lazy VirtualFree calls.

But if you ignore the first 5 cycles of the application, and take a broad enough view over the next 20 cycles of the application, a trend becomes clear.  And if you measure over a long enough period, paltry leaks of 8 or 12 bytes per cycle can be discovered.  Indeed, V1 of the CLR shipped with a leak for a simple application in this test harness that was either 8 or 12 bytes (I can never remember which).  Of that, 4 bytes was a known leak in our design.  It was the data structure that recorded the IDs of all the AppDomains that had been unloaded.  I don’t know if we’ve subsequently addressed that leak.  But in the larger scheme of things, 8 or 12 bytes is pretty impressive.

Recently, one of our test developers has started experimenting with leak detection based on tracing of our unmanaged data structures.  Fortunately, many of these internal data structures are already described to remote processes, to support out-of-process debugging of the CLR.  The idea is that we can walk out from the list of AppDomains, to the list of assemblies in each one, to the list of types, to their method tables, method bodies, field descriptors, etc.  If we cannot reach all the allocated memory blocks through such a walk, then the unreachable blocks are probably leaks.

Of course, it’s going to be much harder than it sounds.  We twiddle bits of pointers to save extra state.  We point to the interiors of heap blocks.  We burn the addresses of some heap blocks, like dynamically generated native code snippets, into JITted code and then otherwise forget about the heap address.  So it’s too early to say whether this approach will give us a sound mechanism for discovering leaks.  But it’s certainly a promising idea and worth pursuing.

**Rambling Security Addendum**

Finally, an off-topic note as I close down:

I haven’t blogged in about a month.  That’s because I spent over 2 weeks (including weekends) on loan from the CLR team to the DCOM team.  If you’ve watched the tech news at all during the last month, you can guess why.  It’s security.

From outside the company, it’s easy to see all these public mistakes and take a very frustrated attitude.  “When will Microsoft take security seriously and clean up their act?”  I certainly understand that frustration.  And none of you want to hear me whine about how it’s unfair.

The company performed a much publicized and hugely expensive security push.  Tons of bugs were filed and fixed.  More importantly, the attitude of developers, PMs, testers and management was fundamentally changed.  Nobody on our team discusses new features without considering security issues, like building threat models.  Security penetration testing is a fundamental part of a test plan.

Microsoft has made some pretty strong claims about the improved security of our products as a result of these changes.  And then the DCOM issues come to light.

Unfortunately, it’s still going to be a long time before all our code is as clean as it needs to be.

Some of the code we reviewed in the DCOM stack had comments about DGROUP consolidation (remember that precious 64KB segment prior to 32-bit flat mode?) and OS/2 2.0 changes.  Some of these source files contain comments from the ‘80s.  I thought that Win95 was ancient!

I’ve only been at Microsoft for 6 years.  But I’ve been watching this company closely for a lot longer, first as a customer at Xerox and then for over a decade as a competitor at Borland and Oracle.  For the greatest part of Microsoft’s history, the development teams have been focused on enabling as many scenarios as possible for their customers.  It’s only been for the last few years that we’ve all realized that many scenarios should never be enabled.  And many of the remainder should be disabled by default and require an explicit action to opt in.

One way you can see this change in the company’s attitude is how we ship products.  The default installation is increasingly impoverished.  It takes an explicit act to enable fundamental goodies, like IIS.

Another hard piece of evidence that shows the company’s change is the level of resource that it is throwing at the problem.  Microsoft has been aggressively hiring security experts.  Many are in a new Security Business Unit, and the rest are sprinkled through the product groups.  Not surprisingly, the CLR has its own security development, PM, test and penetration teams.

I certainly wasn’t the only senior resource sucked away from his normal duties because of the DCOM alerts.  Various folks from the Developer Division and Windows were handed over for an extended period.  One of the other CLR architects was called back from vacation for this purpose.

We all know that Microsoft will remain a prime target for hacking.  There’s a reason that everyone attacks Microsoft rather than Apple or Novell.  This just means that we have to do a lot better.

Unfortunately, this stuff is still way too difficult.  It’s a simple fact that only a small percentage of developers can write thread-safe free-threaded code.  And they can only do it part of the time.  The state of the art for writing 100% secure code requires that same sort of super-human attention to detail.  And a hacker only needs to find a single exploitable vulnerability.

I do think that managed code can avoid many of the security pitfalls waiting in unmanaged code.  Buffer overruns are far less likely.  Our strong-name binding can guarantee that you call who you think you are calling.  Verifiable type safety and automatic lifetime management eliminate a large number of vulnerabilities that can often be used to mount security attacks.  Consideration of the entire managed stack makes simple luring attacks less likely.  Automatic flow of stack evidence prevents simple asynchronous luring attacks from succeeding.  And so on.

But it’s still way too hard.  Looking forwards, a couple of points are clear:

1. We need to focus harder on the goal that managed applications are secure, right out of the box.  This means aggressively chasing the weaknesses of our present system, like the fact that locally installed assemblies by default run with FullTrust throughout their execution.  It also means static and dynamic tools to check for security holes.
2. No matter what we do, hackers will find weak spots and attack them.  The very best we can hope for is that we can make those attacks rarer and less effective.

I’ll add managed security to my list for future articles.
