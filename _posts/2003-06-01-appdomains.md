---
layout: post
title: AppDomains ("application domains")
permalink: appdomains
date: 2003-06-01 12:21:00.000000000 -07:00
status: publish
type: post
published: true
---

An AppDomain is a light-weight process.  Well, if you actually measure the costs associated with an AppDomain – especially the first one you create, which has some additional costs that are amortized over all subsequent ones – then “light-weight” deserves some explanation:

A Win32 process is heavy-weight compared to a Unix process.  A Win32 thread is heavy-weight compared to a Unix thread, particularly if you are using a non-kernel user threads package on Unix.  A good design for Windows will create and destroy processes at a low rate, will have a small number of processes, and will have a small number of threads in each process.

Towards the end of V1, we did some capacity testing using ASP.NET.  At that time, we were able to squeeze 1000 very simple applications / AppDomains into a single worker process.  Presumably that process would have had 50-100 threads active in it, even under heavy load.  If we had used OS processes for each application, we would have 1000 CLRs with 1000 GC heaps.  More disturbing, we would have at least 10,000 threads.  This would reserve 10 GB of VM just for their default 1 MB stacks (though it would only commit a fraction of that memory).  All those threads would completely swamp the OS scheduler.

Also, if you execute a lot of processes, it’s key that those processes are filled with shared pages (for example, the same code loaded at the same preferred addresses) rather than private pages (like dynamically allocated data).  Unfortunately, JITted code results in private pages.  Our NGEN mechanism can be used to create pre-JITted images that can be shared across processes.  But NGEN is not a panacea: NGEN images must be explicitly generated; if their dependencies change through versioning, modifications to security policy, etc., then the loader will reject the images as invalid and quietly fall back on JITting; NGEN images improve load time, but they actually insert a small steady-state cost to some operations, due to indirections; and NGEN can do a worse job of achieving locality than JITting and dynamically loading types (at least in the absence of a training scenario).

Over time, I think you’ll see NGEN address many of these limitations and become a core part of our execution story.

Of course, I wouldn’t recommend that you actually run a process with 1000 AppDomains either.  For example, address space is an increasingly scarce resource – particularly on servers.  The version of the CLR we just shipped now supports 3 GB of user address space, rather than the 2 GB that is normally available.  (You need to boot the system for this, and sacrifice OS buffer space, so don’t do it unless you really need it).  64-bit systems, including a 64-bit CLR, cannot come soon enough for certain scenarios.

Compared to our goals, it still takes too long to create and destroy AppDomains.  The VM and working set hits are too high.  And the cost of crossing an AppDomain boundary is embarrassing.  But the general architecture is sound and you should see improvements in all these areas in future releases.

It’s too simplistic to say that AppDomains are just light-weight OS processes.  There is more to say in several dimensions:

* Security
* Instance lifetime
* Type identity
* Domain-neutrality
* Per-AppDomain state like static fields
* Instance-agility
* Configuration and assembly binding
* Unloading and other resource management
* Programming model

**Security**

Code Access Security only works within an OS process.  Threads freely call through AppDomain boundaries, so the CLR must be able to crawl stacks across those boundaries to evaluate permission demands.  In fact, it can crawl compressed stacks that have been disassociated from their threads, accurately evaluating permissions based on AppDomains that have already been unloaded.

It’s conceivable that one day we will have a sufficiently strong notion of distributed trust that we can usefully propagate compressed stacks into other processes.  However, I don’t expect we’ll see that sort of distributed security for at least another couple of releases.

It’s possible to apply different security policy or different security evidence at the granularity of an AppDomain.  Any grants that would result based on AppDomain evidence and policy are intersected with what would be granted by policy at other levels, like machine or enterprise.  For example, Internet Explorer attaches a different codebase to an AppDomain to indicate the origin of the code that’s running in it.  There are two ways for the host to control security at an AppDomain granularity.  Unfortunately, both techniques are somewhat flawed:

1. The host can pre-load a set of highly-trusted assemblies into an AppDomain.  Then it can modify the security policy to be more restrictive and start loading less-trusted application code.  The new restricted policy will only apply to these subsequent loads.  This approach is flawed because it forces the host to form a closure of the initial highly-trusted set of assemblies.  Whatever technique the host uses here is likely to be brittle, particularly in the face of versioning.  Any dependent assemblies that are forgotten in the initial load will be limited by the restricted policy.  Furthermore, it is unnecessarily expensive to eagerly load assemblies, just so they can escape a particular security policy.

2. The host can load the application assemblies with extra evidence.  When the security system evaluates the grant set for these assemblies, this extra evidence can be considered and the application assemblies will get reduced permissions.  This technique allows the host to lazily load highly trusted assemblies into the same AppDomain, since these won’t have the extra evidence attached to them.  Unfortunately, this technique also has a rough edge.  If an application assembly has a dependency on a second application assembly, what is going to attach extra evidence to the 2nd assembly?  I suppose the host could get the 1st assembly’s dependencies and eagerly load them.  But now we are back on a plan where transitive closures must be eagerly loaded in order to remain secure.  And, in future releases, we would like to give each assembly a chance to run initialization code.  There’s a risk that such initialization code might run and fault in the dependencies before the host can explicitly load them with extra evidence.

We need to do better here in a future release.

Until then, code injection remains a real concern.  A host carefully prepares an AppDomain and loads some partially trusted application code there for execution.  If the application code can inject itself into a different AppDomain (especially the default AppDomain, which is presumably where the fully trusted host is executing), then it can escape the policy and extra evidence that is constraining it.  This is one reason that we don’t provide AppDomain enumeration services to partially trusted code.  If you can find an AppDomain, you can perform an AppDomain.DoCallBack into it passing a delegate.  This has the effect of marshaling the delegate into that AppDomain and then dispatching to it there.  The assemblies containing the delegate and the target of the delegate will be created in the specified AppDomain.

Today, if a host exercises great care, it can use AppDomains as the basis of building a secure environment.  In the future, we would like to reduce the amount of care required of the host.  One obvious way to do this is to involve the host in any assembly loads that happen in any AppDomain.  Unfortunately, that simple approach makes it difficult to make wise decisions on loading assemblies as domain-neutral, as we’ll see later.

**Instance Lifetime**

The CLR contains a tracing GC which can accurately, though non-deterministically, detect whether an object is still reachable.  It is accurate because, unlike a conservative GC, it knows how to find all the references.  It never leaves objects alive just because it can’t distinguish an object reference from an integer with the same coincidental set of bits.  Our GC is non-deterministic because it optimizes for efficient memory utilization.  It collects portions of the GC heap that it predicts will productively return memory to the heap, and only when it thinks the returned memory warrants the effort it will expend.

If the GC can see an orphaned cycle where A refers to B and B refers to A (but neither A nor B are otherwise reachable), it will collect that cycle.  However, you can create cycles that the GC cannot trace through and which are therefore uncollectible.  A simple way to do this is to have object A refer to object B via a GCHandle rather than a normal object reference.  All handles are considered part of the root-set, so B (and thus A) is never collected.

The GC cannot trace through unmanaged memory either.  Any cycles that involve COM objects will be uncollectible.  It is the application’s responsibility to explicitly break the cycle by nulling a reference, or by calling ReleaseComObject, or by some other technique.  Of course, this is standard practice in the COM world anyway.

Nor can the GC trace across processes.  Instead, Managed Remoting uses a system of leases to achieve control over distributed lifetime.  Calls on remote objects automatically extend the lease the client holds.  Leases can trivially be made infinite, in which case the application is again responsible for breaking cycles so that collection can proceed.  Alternatively, the application can provide a sponsor which will be notified before a remote object would be collected.  This gives the application the opportunity to extend leases “on demand”, which reduces network traffic.

By default, if you don’t access a remote object for about 6 minutes, your lease will expire and your connection to that remote object is lost.  You can try this yourself, with a remote object in a 2nd process.  But listen carefully:  you can also try it with a remote object in a 2nd AppDomain.  If you leave your desk for a cup of tea, your cross-AppDomain references can actually timeout and disconnect!

Perhaps one day we will build a distributed GC that is accurate and non-deterministic across a group of processes or even machines.  Frankly, I think it’s just as likely that we’ll continue to rely on techniques like configurable leases for cross-process or cross-machine lifetime management.

However, there’s no good reason for using that same mechanism cross-AppDomain.  There’s a relatively simple way for us to trace object references across AppDomain boundaries – even in the presence of AppDomain unloading.  This would be much more efficient than what we do today, and would relieve developers of a big source of problems.

We should fix this.

**Type Identity**

Managed objects can be marshaled across AppDomain boundaries according to one of several different plans:

* Unmarshalable

  This is the default for all types.  If an object is not marked with the Serializable custom attribute, it cannot be marshaled.  Any attempt to pass such an object across an AppDomain boundary will result in an exception.

* Marshal-by-value

  This is the default for all types that are marked as Serializable, unless they inherit from MarshalByRefObject.  During a single marshal of a graph of objects, identity is preserved.  But if the same object is marshaled on two separate calls from AppDomain1 to AppDomain2, this will result in two unrelated instances in AppDomain2.

* Marshal-by-reference

  Any Serializable types that inherit from System.MarshalByRefObject will marshal by reference.  This causes an identity-preserving proxy to be created in the client’s AppDomain.  Most calls and any field accesses on this proxy will remote the operation back to the server’s AppDomain.  There are a couple of calls, defined on System.Object (like GetType), which might actually execute in the client’s AppDomain.

* Marshal-by-bleed

  Certain objects are allowed to bleed.  For the most part, this bleeding is an optional performance optimization.  For example, if you pass a String object as an argument on a call to a remoted MarshalByRefObject instance, the String is likely to bleed across the AppDomain boundary.  But if you create a value type with an Object[] field, put that same String into the Object[], and pass the struct, the current marshaler might not bleed your String.  Instead, it’s likely to be marshaled by value.

  In other cases, we absolutely require that an instance marshal by bleed.  System.Threading.Thread is a good example of this.  The same managed thread can freely call between AppDomains.  Since the current marshaler cannot guarantee that an instance will always bleed, we have made Thread unmarshalable by the marshaler for now.  Then the CLR bleeds it without using the marshaler when you call Thread.CurrentThread.

* Identity-preserving marshal-by-value

  As we’ve seen, objects which marshal by value only preserve identity in a single marshaling operation, like a single remoted call.  This means that, the more you call, the more objects you create.  This is unacceptable for certain objects, like certain instances of System.Type.  Instead, we marshal the type specifier from one AppDomain to another, effectively do a type load in the 2nd AppDomain (finding any corresponding type that has already been loaded, of course) and then treat that type as the result of the unmarshal.

* Custom marshaling

  The Managed Remoting and serialization architectures are quite flexible.  They contain sufficient extensibility for you to define your own marshaling semantics.  Some researchers at Microsoft tried to build a system that transparently migrated objects to whatever client process was currently using them.  I’m not sure how far they got.

How does all this relate to type identity?  Well, instances of System.Type, and the metaobjects reachable from them like MethodInfos and PropertyInfos, can be marshaled in two different ways.  If the underlying assembly was loaded as domain-neutral into the two AppDomains involved in a remote operation, then the metaobjects from that assembly will be marshaled-by-bleed.  If instead the underlying assembly was loaded per-domain, then the metaobjects from that assembly will be identity-preserving marshaled-by-value.

**Domain-neutrality**

So what’s this domain-neutral vs. per-domain distinction?  Remember when I said that a key to good performance is to have lots of shared pages and to minimize private pages?  At the time, I was talking about sharing pages across processes.  But the same is true of sharing pages across AppDomains.  If all the AppDomains in a process can use the same JITted code, MethodTables, MethodDescs and other runtime structures, this will give us a dramatic performance boost when we create more AppDomains in that process.

If an assembly is loaded domain-neutral, we just mean that all these data structures and code are available in all the different AppDomains.  If that same assembly is loaded per-domain, we have to duplicate all those structures between AppDomains.

In V1 and V1.1 of the CLR, we offer the following policies for determining which assemblies should be domain-neutral:

1. Only share mscorlib.dll.  This choice is the default.  We must always share mscorlib, because the operating system will only load one copy of mscorwks.dll (the CLR) into a process.  And there are many 1:1 references backwards and forwards between mscorwks and mscorlib.  For this reason, we need to be sure there’s only a single mscorlib.dll, shared across all the different AppDomains.

2. Share all strongly-named assemblies.  This is the choice made by ASP.NET.  It’s a reasonable choice for them because all ASP.NET infrastructure is strongly-named and happens to be used in all AppDomains.  The code from web pages is not strongly-named and tends to be used only from a single AppDomain anyway.

3. Share all assemblies.  I’m not aware of any host or application which uses this choice.

Wait a second.  If sharing pages is such a great idea, why isn’t everyone using “Share all assemblies”?  That’s because domain-neutral code has a couple of drawbacks.  First and most importantly, domain-neutral code can never be unloaded.  This is an unfortunate consequence of our implementation, though fixing it will be quite hard.  It may be several more releases before we even try.

A second drawback is that domain-neutral code introduces a few inefficiencies.  Usually the working set benefits quickly justify these inefficiencies, but there may be some scenarios (like single-AppDomain processes!) where this isn’t true.  These inefficiencies include a 1:M lookup on all static field accesses and some high costs associated with deciding when to execute class constructors.  That’s because the code is shared across all AppDomains, yet each AppDomain needs its own copy of static fields which are initialized through its own local execution of a .cctor method.  You can reduce the overhead associated with .cctors (whether in domain-neutral code or not) by marking your .cctors with tdBeforeFieldInit.  I’ve mentioned this in prior blogs.

Finally, in V1 & V1.1, we don’t allow you to combine NGEN with domain-neutral code.  This may not be a concern for you, given the other limitations associated with NGEN today.  And I’m confident that we’ll remove this particular restriction in a future release.

Okay, but this still sucks.  Why are these choices so limited?  Ideally a host would specify a set of its own assemblies and some FX assemblies for sharing.  Since these assemblies would be intrinsic to the operation of the host, it wouldn’t matter that they can never unload.  Then the application assemblies would be loaded per-domain.

We can’t support this because, if one assembly is loaded as domain-neutral, all the other assemblies in its binding closure must also be loaded as domain-neutral.  This requirement is trivially satisfied by the first and third policies above.  For the 2nd policy, we rely on the fact that strong-named assemblies can only early-bind to other strong-named assemblies.

If we didn’t require an entire binding closure to be domain-neutral, then references from a domain-neutral assembly to a per-domain assembly would require a 1:M lookup, similar to what we do for static field accesses.  It’s easy to see how this sort of lookup can work for static field access.  But it’s much harder to see what kind of indirections would allow a domain-neutral type to inherit from a per-domain one.  All the instance field offsets, base class methods, and VTable slots would need biasing via a 1:M lookup.  Ouch.

In fact, long term we’re not trying to find some more flexible policies for a host to specify which assemblies can be loaded domain-neutral.  It’s evil to have knobs that an application must set.  We really want to reach a world where the CLR makes sensible decisions on the most appropriate way to execute any application.  To get there, we would like to remove the inefficiencies and differing semantics associated with domain-neutral code and make such assemblies unloadable.  Then we would like to train our loader to notice those AppDomains which will necessarily make identical binding decisions (more on this later).  This will result in maximum automatic sharing.

It’s not yet clear whether/when we can achieve this ideal.

**Per-AppDomain state like static fields**

As stated above, domain-neutrality would ideally be a transparent optimization that the system applies on behalf of your application.  There should be no observable semantics associated with this decision, other than performance.

Whether types are domain-neutral or not, each AppDomain must get its own copy of static fields.  And a class constructor must run in each of those AppDomains, to ensure that these static fields are properly initialized.

**Instance-agility**

We just discussed how domain-neutrality refers to assemblies and how they are shared between AppDomains.  Instance-agility refers to object instances and how they are allowed to flow between AppDomains.

An agile instance must necessarily be of a type we loaded as domain-neutral.  However, the converse is not true.  The vast majority of domain-neutral types do not have agile instances.

If an instance marshals-by-bleed or if it performs identity-preserving marshal-by-value, then by definition it is agile.  The effect is the same in both cases: it’s possible to have direct references to the same instance from multiple AppDomains.

This is in contrast to normal non-agile instances which are created, live and die in a single AppDomain.  We don’t bother to track which AppDomain these instances belong to, because we can infer this.  If a thread is accessing an instance, then the instance is clearly in the same AppDomain that the thread is currently executing in.  If we find references to an instance further back on a thread’s stack, then we can use the AppDomain transitions which are recorded on that stack to determine the correct AppDomain.  And – for per-domain types – the type itself can tell us which AppDomain the instance belongs to.

Although we don’t normally track the AppDomain which contains an instance, there are some exceptions.  For example, a Finalizable object must be finalized in the AppDomain it lives in.  So when an instance is registered for finalization, we always record the current AppDomain at that time.  And the finalizer thread(s) take care to batch up instances in the same AppDomain to minimize transitions.

For an instance to be agile, it must satisfy these rules:

* It must be of a type that was loaded as domain-neutral.  (Today, we restrict ourselves to types in mscorlib.dll, which is always domain-neutral).
* The type must not be unloaded until the last instance has died.  (Today, we never unload these types).
* Instances must not have references to any other instances that are not themselves agile.

Based on these rules, it’s actually possible for the loader to identify some types as having legally agile instances.  System.String is a good example, because it is sealed and has no references to other instances.  However, this automatic detection would be inadequate for our purposes.  We need some additional objects like System.Threading.Thread to be agile.  Since Thread can contain references to many objects that are clearly not agile (like managed thread local storage, which contains arbitrary application objects), we have to be very careful here.

In this case, being careful means that we partition some of the Thread’s state in a per-AppDomain manner.

If you’ve read my earlier blogs, you know that static fields can be per-AppDomain, per-Thread, per-Context, or per-process (RVA-based statics).  Now you know why the per-Thread and per-Context statics are still partitioned by AppDomain.  And you understand why the per-process statics are restricted from containing arbitrary object references.  They can only contain scalars, Strings (agile instances!) and value types that are themselves similarly constrained.

If you’ve done much debugging with AppDomains and exceptions, you’ve probably noticed that the first pass of exception handling is always terminated at an AppDomain boundary.  It’s annoying: if the exception goes unhandled and you take your last chance as a trap to the debugger, you’ve lost the original context of the exception.  But now it’s clear why this happens.  If an exception instance isn’t agile, it must be marshaled from one AppDomain to the next as the dispatch occurs.  (We make a special exception for an AppDomain-agile OutOfMemoryException that we pre-create, so that it’s available when we don’t have enough memory to make a per-AppDomain instance).

In fact, there’s a lot of complexity involved in ensuring that instances are only accessible from one AppDomain, or that they follow the discipline necessary for agility.  You may be wondering why we care.  We care because AppDomain isolation is a fundamental guarantee of the managed environment, on which many other guarantees can be built.  In this sense, it is like separate address spaces for OS processes.  Because of AppDomain isolation, we can build certain security guarantees and we can reclaim resources correctly when AppDomains are unloaded.

**Configuration and Assembly Binding**

Since each AppDomain is expected to execute a different application, each AppDomain can have its own private paths for binding to its assemblies, its own security policy, and in general its own configuration.  Even worse, a host can listen to the AssemblyResolveEvent and dynamically affect binding decisions in each AppDomain.  And the application can modify configuration information like the AppDomain’s private path – even as it runs.  This sets up terrible data races, which rely on unfortunate side effects like the degree of inlining the JIT is performing and how lazy or aggressive the loader is in resolving dependent assemblies.  Applications that rely on this sort of thing are very fragile from one release of the CLR to the next.

This also makes it very difficult for the loader to make sensible and efficient decisions about what assemblies can be shared.  To do a perfect job, the loader would have to eagerly resolve entire binding closures in each AppDomain, to be sure that those AppDomains can share a single domain-neutral assembly.

Frankly, we gave the host and the application a lot of rope to hang themselves.  In retrospect, we screwed up.

I suspect that in future versions we will try to dictate some reasonable limitations on what the host and the AppDomain’s configuration can do, at least in those cases where they want efficient and implicit sharing of domain-neutral assemblies to happen.

**Unloading**

A host or other sufficiently privileged code can explicitly unload any AppDomain it has a reference to, except for the default AppDomain which is not unloadable.  The default AppDomain is the one that is created on your behalf when the process starts.  This is the AppDomain a host typically chooses for its own execution.

The steps involved in an unload operation are generally as follows.  As in many of these blogs, I’m describing implementation details and I’m doing so without reading any source code.  Hopefully the reader can distinguish the model from the implementation details to understand which parts of the description can change arbitrarily over time.

* Since the thread that calls AppDomain.Unload may itself have stack in the doomed AppDomain, a special helper thread is created to perform the unload attempt.  This thread is cached, so every Unload doesn’t imply creation of a new thread.  If we had a notion of task priorities in our ThreadPool, we would be using a ThreadPool thread here.

* The unload thread sends a DomainUnload event to any interested listeners.  Nothing bad has happened yet, when you receive this event.

* The unload thread freezes the runtime.  This is similar to the freeze that happens during (portions of) a garbage collection.  It results in a barrier that prevents all managed execution.

* While the barrier is in place for all managed execution, the unload thread erects a finer-grained barrier which prevents entry into the doomed AppDomain.  Any attempt to call in will be rejected with a DomainUnloaded exception.  The unload thread also examines the stacks of all managed threads to decide which ones must be unwound.  Any thread with stack in the doomed AppDomain – even if it is currently executing in a different AppDomain – must be unwound.  Some threads might have multiple disjoint regions of stack in the doomed AppDomain.  When this is the case, we determine the base-most frame that must be unwound before this thread is no longer implicated in the doomed AppDomain.

* The unload thread unfreezes the runtime.  Of course, the finer-grained barrier remains in place to prevent any new threads from entering the doomed AppDomain.

* The unload thread goes to work on unwinding the threads that it has identified.  This is done by injecting ThreadAbortExceptions into those threads.  Today we do this in a more heavy-weight but more scalable fashion than by calling Thread.Abort() on each thread, but the effect is largely the same.  As with Thread.Abort, we are unable to take control of threads that are in unmanaged code.  If such threads are stubborn and never return to the CLR, we have no choice but to timeout the Unload attempt, undo our partial work, and return failure to the calling thread.  Therefore, we are careful to unwind the thread that called Unload only after all the others have unwound.  We want to be sure we have a thread to return our failure to, if a timeout occurs!

* When threads unwind with a ThreadAbortException, the Abort is propagated in the normal undeniable fashion.  If a thread attempts to catch such an exception, we automatically re-raise the exception at the end of the catch clause.  However, when the exception reaches that base-most frame we identified above, we convert the undeniable ThreadAbortException to a normal DomainUnloaded exception.

* No threads can execute in the doomed AppDomain – except for a Finalizer thread which is now given a special privilege.  We tell the Finalizer thread to scan its queue of ready-to-run finalizable objects and finalize all the ones in this AppDomain.  We also tell it to scan its queue of finalizable but still reachable objects (not ready to run, under normal circumstances) and execute them, too.  In other words, we are finalizing reachable / rooted objects if they are inside the doomed AppDomain.  This is similar to what we do during a normal process shutdown.  Obviously the act of finalization can create more finalizable objects.  We keep going until they have all been eliminated.

* During finalization, we are careful to skip over any agile reachable instances like Thread instances that were created in this AppDomain.  They effectively escape from this AppDomain in a lazy fashion at this time.  When these instances are eventually collected, they will be finalized in the default AppDomain, which is as good as anywhere else.

* If we have any managed objects that were exposed to COM via CCWs, their lifetimes are partially controlled via COM reference counting rules.  If the managed objects are to agile instances, we remove them from their AppDomain’s wrapper cache and install them in the default AppDomain’s wrapper cache.  Like other agile objects, they have lazily survived the death of the AppDomain they were created in.

* For all the non-agile CCWs (the vast majority), the managed objects are about to disappear.  So we bash all the wrappers so that they continue to support AddRef and Release properly.  All other calls return the appropriate HRESULT for DomainUnloadedException.  The trick here, of course, is to retain enough metadata to balance the caller’s stack properly.  When the caller drives the refcount to 0 on each wrapper, it will be cleaned up.

* Now we stop reporting all the handles, if they refer to the doomed AppDomain, and we trigger a full GC.  This should collect all the objects that live in this AppDomain.  If it fails to do so, we have a corrupted GC heap and the process will soon die a terrible death.

* Once this full GC has finished, we are free to unmap all the memory containing JITted code, MethodTables, MethodDescs, and all the other constructs.  We also unload all the DLLs that we loaded specifically for this AppDomain.

In a perfect world, that last step returns all the memory associated with the AppDomain.  During V1, we had a leak detection test that tried to verify this.  Once we reached a steady-state in the test cycle, after unloading the first few AppDomains, we got pretty close to our ideal.  It’s harder to measure than you might imagine, due to things like delayed coalescing of OS heap structures.  According to our measurements, we were leaking 12 bytes per unloaded AppDomain – of which 4 bytes was almost by design.  (It was the ID of the unloaded AppDomain).  I have no idea how well we are doing these days.

In a scenario where lots of unloads are happening, it’s unfortunate that we do a full GC for each one.  For those cases, we would like to defer the full GC and the reclamation of resources until the next time that the GC is actually scheduled.  …One day.

There’s so much more I had intended to write about.  For example, some ambiguities exist when unmanaged (process-wide) code calls into Managed C++ and has to select a target AppDomain.  This can be controlled by flags in the VTFixup entries that are used by the IJW thunks.  And customers often ask us for alternatives to AppDomain unloading, like unloading individual methods, unloading individual assemblies, or unloading unreferenced domain-neutral assemblies.  There are many interesting programming model issues, like the reason why we have a CreateInstance**AndUnwrap** method on AppDomain.

But even I think this blog is getting way too long.
