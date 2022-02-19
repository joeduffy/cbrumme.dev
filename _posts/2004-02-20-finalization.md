---
layout: post
title: Finalization
permalink: finalization
date: 2004-02-20 22:27:00.000000000 -07:00
status: publish
type: post
published: true
---

Earlier this week, I wrote an internal email explaining how Finalization works in V1 / V1.1, and how it has been changed for Whidbey.  There’s some information here that folks outside of Microsoft might be interested in.

**Costs**

Finalization is expensive.  It has the following costs:

1. Creating a finalizable object is slower, because each such object must be placed on a RegisteredForFinalization queue.  In some sense, this is a bit like having an extra pointer-sized field in your object that the system initializes for you.  However, our current implementation uses a slower allocator for every finalizable object, and this impact can be measured if you allocate small objects at a high rate.

2. Each GC must do a weak pointer scan of this queue, to find out whether any finalizable objects are now collectible.  All such objects are then moved to a ReadyToFinalize queue.  The cost here is small.

3. All objects in the ReadyToFinalize queue, and all objects reachable from them, are then marked.  This means that an entire graph of objects which would normally die in one generation can be promoted to the next generation, based on a single finalizable root to this graph.  Note that the size of this graph is potentially huge.

4. The older generation will be collected at some fraction of the frequency of the younger generation.  (The actual ratio depends on your application, of course).  So promotion of the graph may have increased the time to live of this graph by some large multiple.  For large graphs, the combined impact of this item and #3 above will dominate the total cost of finalization.

5. We currently use a single high priority Finalizer thread to walk the ReadyToFinalize queue.  This thread dequeues each object, executes its Finalize method, and proceeds to the next object.  This is the one cost of finalization which customers actually expect.

6. Since we dedicate a thread to calling finalizers, we inflict an expense on every managed process.  This can be significant in Terminal Server scenarios where the high number of processes multiplies the number of finalizer threads.

7. Since we only use a single thread for finalization, we are inherently non-scalable if a process is allocating finalizable objects at a high rate.  One CPU performing finalization might not keep up with 31 other CPUs allocating those finalizable objects.

8. The single finalizer thread is a scarce resource.  There are various circumstances where it can become blocked indefinitely.  At that point, the process will leak resources at some rate and eventually die.  See http://cbrumme.dev/apartments-and-pumping for extensive details.

9. Finalization has a conceptual cost to managed developers.  In particular, it is difficult to write correct Finalize methods as I shall explain.

Eventually we would like to address #5 thru #8 above by scheduling finalization activity over our ThreadPool threads.  We have also toyed with the idea of reducing the impact of #3 and #4 above, by pruning the graph based on reachability from your Finalize method and any code that it might call.  Due to indirections that we cannot statically explore, like interface and virtual calls, it’s not clear whether this approach will be fruitful.  Also, this approach would cause an observable change in behavior if resurrection occurs.  Regardless, you should not expect to see any of these possible changes in our next release.

**Reachability**

One of the guidelines for finalization is that a Finalize method shouldn’t touch other objects.  People sometimes incorrectly assume that this is because those other objects have already been collected.  Yet, as I have explained, the entire reachable graph from a finalizable object is promoted.

The real reason for the guideline is to avoid touching objects that may have already been finalized.  That’s because finalization is unordered.

So, like most guidelines, this one is made to be broken under certain circumstances.  For instance, if your object “contains” a private object that is not itself finalizable, clearly you can refer to it from your own Finalize method without risk.

In fact, a sophisticated developer might even create a cycle between two finalizable objects and coordinate their finalization behavior.  Consider a buffer and a file.  The Finalize method of the buffer will flush any pending writes.  The Finalize method of the file will close the handle.  Clearly it’s important for the buffer flush to precede the handle close.  One legitimate but brittle solution is to create a cycle of references between the buffer and the file.  Whichever Finalize method is called first will execute a protocol between the two objects to ensure that both side effects happen in order.  The subsequent Finalize call on the second object should do nothing.

I should point out that Whidbey solves the buffer and file problem differently, relying on the semantics of critical finalization.  And I should also point out that any protocol for sequencing the finalization of two objects should anticipate that one day we may execute these two Finalize methods concurrently on two different threads.  In other words, the protocol must be thread-safe.

**Ordering**

This raises the question of why finalization is unordered.

In many cases, no natural order is even possible.  Finalizable objects often occur in cycles.  You could imagine decorating some references between objects, to indicate the direction in which finalization should proceed.  This would add a sorting cost to finalization.  It would also cause complexity when these decorated references cross generation boundaries.  And in many cases the decorations would not fully eliminate cycles.  This is particularly true in component scenarios, where no single developer has sufficient global knowledge to create an ordering:

Your component would achieve its guarantees when tested by you, prior to deployment.  Then in some customer application, additional decorated references would create cycles and your guarantees would be lost.  This is a recipe for support calls and appcompat issues.

Unordered finalization is substantially faster.  Not only do we avoid sorting (which might involve metadata access and marking through intermediate objects), but we can also efficiently manage the RegisteredForFinalization and ReadyToFinalize queues without ever having to memcpy.  Finally, there’s value in forcing developers to write Finalize methods with minimal dependencies on any other objects.  This is key to our eventual goal of making Finalization scalable by distributing it over multiple threads.

Based on the above and other considerations like engineering complexity, we made a conscious decision that finalization should be unordered.

**Partial Trust**

There are no security permissions associated with the definition of a Finalize method.  As we’ve seen, it’s possible to mount a denial of service attack via finalization.  However, many other denial of service attacks are possible from partial trust, so this is uninteresting.

Customers and partners sometimes ask why partially trusted code is allowed to participate in finalization.  After all, Finalize methods are typically used to release unmanaged resources.  Yet partially trusted code doesn’t have direct access to unmanaged resources.  It must always go through an API provided by an assembly with UnmanagedCodePermission or some other effective equivalent to FullTrust.

The reason is that finalization can also be used to control pure managed resources, like object pools or caches.  I should point out that techniques based on weak handles can be more efficient than techniques based on finalization.  Nevertheless, it’s quite reasonable for partially trusted code to use finalization for pure managed resources.

SQL Server has a set of constraints that they place on partially trusted assemblies that are loaded into their environment.  I believe that these constraints prevent definition of static fields (except for initonly and literal static fields), use of synchronization, and the definition of Finalize methods.  However, these constraints are not related to security.  Rather, they are to improve scalability and reliability of applications by simplifying the threading model and by moving all shared state into the database where it can be transacted.

It’s hard to implement Finalize perfectly

Even when all Finalize methods are authored by fully trusted developers, finalization poses some problems for processes with extreme availability requirements, like SQL Server.  In part, this is because it’s difficult to write a completely reliable Finalize method – or a completely reliable anything else.

Here are some of the concerns specifically related to finalization.  I’ll explain later how some of these concerns are addressed in the context of a highly available process like SQL Server.

Your Finalize method must tolerate partially constructed instances

It’s possible for partially trusted code to subtype a fully trusted finalizable object (with APTCA) and throw an exception from the constructor.  This can be done before chaining to the base class constructor.  The result is that a zero-initialized object is registered for finalization.

Even if partially trusted code isn’t intentionally causing finalization of your partially constructed instances, asynchronous problems like StackOverflowException, OutOfMemoryException or AppDomainUnloadException can cause your constructor to be interrupted at a fairly arbitrary location.

<ins>Your Finalize method must consider the consequence of failure</ins>

It’s possible for partially trusted code to subtype a fully trusted finalizable object (with APTCA) and fail to chain to the base Finalize method.  This causes the fully trusted encapsulation of the resource to leak.

Even if partially trusted code isn’t intentionally causing finalization of your object to fail, the aforementioned asynchronous exceptions can cause your Finalize method to be interrupted at a fairly arbitrary location.

In addition, the CLR exposes a GC.SuppressFinalize method which can be used to prevent finalization of any object.  Arguably we should have made this a protected method on Object or demanded a permission, to prevent abuse of this method.  However, we didn’t want to add a member to Object for such an obscure feature.  And we didn’t want to add a demand, since this would have prevented efficient implementation of IDisposable from partial trust.

<ins>Your object is callable after Finalization</ins>

We’ve already seen how all the objects in a closure can access each other during finalization.  Indeed, if any one of those objects re-establishes its reachability from a root (e.g. it places itself into a static field or a handle), then all the other objects it reaches will also become re-established.  This is referred to as resurrection.  If you have a finalizable object that is publicly exposed, you cannot prevent your object from becoming resurrected.  You are at the mercy of all the other objects in the graph.

One possible solution here is to set a flag to indicate that your object has been finalized.  You can pepper your entire API with checks to this flag, throwing an ObjectDisposedException if you are subsequently called.  Yuck.

<ins>Your object is callable during Finalization</ins>

It’s true that the finalizer thread is currently single-threaded (though this may well change in the future).  And it’s true that the finalizer thread will only process instances that – at some point – were discovered to be unreachable from the application.  However, the possibility of resurrection means that your object may become visible to the application before its Finalize method is actually called.  This means that application threads and the finalizer thread can simultaneously be active in your object.

If your finalizable object encapsulates a protected resource like an OS handle, you must carefully consider whether you are exposed to threading attacks.  Shortly before we shipped V1, we fixed a number of handle recycling attacks that were due to race conditions between the application and Finalization.  See http://cbrumme.dev/lifetime for more details.

<ins>Your Finalizer could be called multiple times</ins>

Just as there is a GC.SuppressFinalize method, we also expose a GC.ReRegisterForFinalize method.  And the same arguments about protected accessibility or security demands apply to the ReRegisterForFinalize method.

<ins>Your Finalizer runs in a delicate security context</ins>

As I’ve explained in prior blogs, the CLR flows the compressed stack and other security information around async points like ThreadPool.QueueUserWorkItem or Control.BeginInvoke.  Indeed, in Whidbey we include more security information by default.  However, we do not flow any security information from an object’s constructor to an object’s Finalize method.  So (to use an absurd example) if you expose a fully trusted type that accepts a filename string in its constructor and subsequently opens that file in its Finalize method, you have created a security bug.

Clearly it’s hard to write a correct Finalize method.  And the managed platform is supposed to make hard things easier.  I’ll return to this when I discuss the new Whidbey features of SafeHandles, Critical Finalizers and Constrained Execution Regions.

But what guarantees do I get if I don’t use any of those new gizmos?  What happens in a V1 or V1.1 process?

**V1 & V1.1 Finalization Guarantees**

If you allocate a finalizable object, we guarantee that it will be registered for finalization.  Once this has happened, there are several possibilities:

1. As part of the natural sequence of garbage collection and finalization, the finalizer thread dequeues your object and finalizes it.

2. The process can terminate without cooperating with the CLR’s shutdown code.  This can happen if you call TerminateProcess or ExitProcess directly.  In those cases, the CLR’s first notification of the shutdown is via a DllMain DLL_PROCESS_DETACH notification.  It is not safe to call managed code at that time, and we will leak all the finalizers.  Of course, the OS will do a fine job of reclaiming all its resources (including abandonment of any cross-process shared resources like Mutexes).  But if you needed to flush some buffers to a file, your final writes have been lost.

3. The process can terminate in a manner that cooperates with the CLR’s shutdown code.  This includes calling exit() or returning from main() in any unmanaged code built with VC7 or later.  It includes System.Environment.Exit().  It includes a shutdown triggered from a managed EXE when all the foreground threads have completed.  And it includes shutdown of processes that are CLR-aware, like VisualStudio.  In these cases, the CLR attempts to drain both the ReadyToFinalize and the RegisteredForFinalization queues, processing all the finalizable objects.

4. The AppDomain containing your object is unloaded.  Prior to Whidbey, the AppDomain will not unload until we have scanned the ReadyToFinalize and the RegisteredForFinalization queues, processing all the finalizable objects that live in the doomed AppDomain.

There are a few points to note here.

* Objects are always finalized in the AppDomain they were created in.  A special case exists for any finalizable objects that are agile with respect to AppDomains.  To my knowledge, the only such type that exists is System.Threading.Thread.

* I have heard that there is a bug in V1 and V1.1, where we get confused on AppDomain transitions in the ReadyToFinalize queue.  The finalization logic attempts to minimize AppDomain transitions by noticing natural partitions in the ReadyToFinalize queue.  I’m told there is a bug where we may occasionally skip finalizing the first object of a partition.  I don’t believe any customers have noticed this and it is fixed in Whidbey.

* Astute readers will have noticed that during process shutdown and AppDomain unloading we actually finalize objects in the RegisteredForFinalization queue.  Such objects are still reachable and would not normally be subject to finalization.  Normally a Finalize method can rely on safely accessing finalizable state that is rooted via statics or some other means.  You can detect when this is no longer safe by checking AppDomain.IsFinalizingForUnload or Environment.HasShutdownStarted.

* Since there is no ordering of finalization, critical infrastructure is being finalized along with application objects.  This means that WaitHandles, remoting infrastructure and even security infrastructure is disappearing underneath you.  This is a potential security concern and a definite reliability concern.  We have spot-fixed a few cases of this.  For example, we never finalize our Thread objects during process shutdown.

* Finalization during process termination will eventually timeout.  If a particular Finalize method gets stuck, or if the queue isn’t reducing in size over time (i.e. you create 2 new finalizable instances out of each execution of your Finalize method), we will eventually timeout and terminate the process.  The exact timeouts depend on whether a profiler is attached and other details.

* The thread that initiates process shutdown performs the duties of “watchdog.”  It is responsible for detecting timeouts during process termination.  If this thread is an STA thread, we cause it to pump COM calls in and out of the STA while it blocks as watchdog.  If the application has a deadlock that implicates the STA thread while it is executing these unmanaged COM calls, then the timeout mechanism is defeated and the process will hang.  This is fixed in Whidbey.

* Subject to all of the above, we guarantee that we will dequeue your object and initiate a call to the Finalize method.  We do not guarantee that your Finalize method can be JITted without running out of stack or memory.  We do not guarantee that the execution of your Finalize method will complete without being aborted.  We do not guarantee that any types you require can be loaded and have their .cctors run.  All you get is a “best effort” attempt.  We’ll soon see how Whidbey extensions allow you to do better than this and guarantee full execution.

* (If you want to know more about the shutdown of managed processes, see http://cbrumme.dev/startup-shutdown.)

**SafeHandle**

Whidbey contains some mechanisms that address many of the V1 and V1.1 issues with finalization.  Let’s start with SafeHandle, since it’s the easiest to understand.  Conceptually, this is just an encapsulation of an OS handle.  You should read the documentation of this feature for details.  Briefly, SafeHandle provides the following benefits:

1. Someone else wrote it and is maintaining it.  Using it is much easier than building equivalent functionality yourself.

2. It prevents races between an application thread and the finalizer thread in unmanaged code.  And it does this in a manner that leverages the type system.  Specifically, clients are forced to deal with SafeHandles rather than IntPtrs or value types which don’t have strong identity and lifetime semantics.

3. It prevents handle-recycling attacks.  You can read more details about finalization races (#2 above) and this bullet on handle-recycling attacks by reading http://cbrumme.dev/lifetime.  In that blog from last April, I allude to the existence of SafeHandle without giving details.

4. It discourages promotion of large graphs of objects, by placing the finalizable resources in a tiny leaf instance.

5. It participates with the PInvoke marshaler to ensure that unmarshaled instances will be registered for finalization.

6. For the handful of bizarre APIs that aren’t covered by our standard marshaling styles, Constrained Execution Regions (CERs) can be used to guarantee that unmarshaled instances will be registered for finalization.

7. It uses the new Critical Finalization mechanism to guarantee that leaks cannot occur.  This means that we not only guarantee we will initiate execution of your Finalize method, but we also make some strong guarantees that allow you to ensure that it actually completes execution.

8. In order to guarantee that there will be no leaks, we necessarily leave the system open to denial of service and hangs.  This is the halting problem.  The Critical Finalization mechanism addresses this dilemma by making the leak protection explicit, restricting it to small regions of carefully written code, and by using the security system.  Only trusted code can achieve strong guarantees about leakage.  Such code is trusted not to create denial of service problems, whether maliciously or inadvertently, over small blocks of explicitly identified code.

9. Since SafeHandle uses Critical Finalization, it solves the problem of sequencing buffer flushing before handle closing that I mentioned earlier.

So what is this Critical Finalization thing?

**Critical Finalization (CF) and CERs**

Any object that derives from CriticalFinalizerObject (including SafeHandle) obtains critical finalization.  This means:

1. Before any objects of this type are created, the CLR will “prepare” any resources that will be necessary for the Finalize method to run.  Preparation includes JITting the code, running class constructors and – most importantly – traversing the static reachability of other methods and types that will be required during execution and making sure that they are likewise prepared.  However, the CLR cannot statically traverse through indirections like interface calls and virtual calls.  So there is a mechanism for the developer to guide the CLR through these opaque indirections.

2. The CLR will never timeout on the execution of one of these Finalize methods.  As I mentioned, we rely on the limited amount of code written via this discipline combined with the trust decisions of the security system to avoid hangs here.

3. When the Finalize method is called, it is called in a protected state that prevents the CLR from injecting Thread.Aborts or other optional asynchronous exceptions.  Because of our special preparation, we also prevent other asynchronous exceptions like OutOfMemoryExceptions due to JITting or type loading and TypeInitializationExceptions due to .cctors failures.  Of course, if the application tries to allocate an object it may get an OutOfMemoryException.  This is application-induced rather than system-induced and therefore is not considered the CLR’s responsibility.  The Finalize method can use standard exception handling to protect itself here.

4. All normal finalizable objects are either executed or discarded without finalization, before any critical finalizers are executed.  This means that a buffer flush can precede the close of the underlying handle.

The first 3 bullet points above are not restricted to CF.  These bullet points apply to all CERs.  The fundamental difference between CF and other CERs is the funky flow control from the instantiation of an object to the execution of its Finalize method via registration on our finalization queues.  Other CERs can use normal block scopes in a single method to express the same reliability concepts.  For normal CERs, the preparation phase, the forward execution phase and the backout phases are all contained in a single method.

A full description of CERs is beyond the scope of a note that is ostensibly about finalization.  However, a brief description makes sense.

Essentially, CERs address issues with asynchronous exceptions.  I have already mentioned asynchronous exceptions, which is the CLR’s term for all the pesky problems that manifest themselves as surprising exceptions.  These are distinct from the application-level exceptions, which presumably are anticipated by and handled by the application.

You can read about asynchronous exceptions and the novel problems introduced by a managed execution environment that virtualizes resources so aggressively at http://cbrumme.dev/reliability.

In V1 and V1.1, the CLR does a poor job of distinguishing asynchronous exceptions from application exceptions.  In Whidbey, we are starting to make this separation but it remains one of the weak design points for our hosting and exception stories.

Anyway, I’m sure that many readers are familiar with the difficulty of writing reliable unmanaged code that is guaranteed to complete in the face of limited resources (e.g. memory or stack), free threading, and other facts of life.  And by now, if you’ve read all the blog articles I’ve mentioned, you are also familiar with the additional problems caused by a highly virtualized execution environment.

CERs allow you to declare regions of code where the CLR is constrained from injecting any system-generated errors.  And the author of the code is constrained from performing certain actions if he wants to avoid additional exceptions.  An obvious example is that he shouldn’t new up an object if he is not prepared to deal with an OutOfMemoryException from that operation.

In addition to CERs, Whidbey provides reliability contracts.  These contracts can be used to annotate methods with their guarantees and requirements with respect to reliability.  Using these contracts, it’s possible to compose reliable execution out of components written by different authors.  This is necessary for building reliable applications that make use of framework services.  If the reliability requirements and guarantees of the framework services were not themselves explicit, the client applications could not remain reliable on top of them.

**Finalization in SQL Server and other high availability hosts**

Back to finalization.

In a normal unhosted process, there isn’t a strong distinction between normal and critical finalization.  Normal processes won’t run out of memory, and if they do they should probably Fail Fast.  It’s unlikely that the risk of trying to continue execution after resource exhaustion is worth the increased risk of subsequent crashes, hangs or other corruptions.  Normal processes won’t experience Thread.Aborts that are injected across threads.  (As opposed to aborting the current thread, which is no more dangerous than throwing any other exception).

So the only real concern is whether all the finalizable objects will drain during process exit, before the timeouts kick in.  The timeouts are quite generous and in practice this is not a concern.

However, a hosted process like SQL Server is quite different.  Because of SQL Server’s availability requirements, it is vital that the process not FailFast for something innocuous like OutOfMemoryExceptions.  Indeed, SQL Server tries to run on the brink of memory exhaustion for performance reasons, so these memory exceptions are a constant fact of life in that environment.  Furthermore, SQL Server uses Thread.Abort explicitly across threads to terminate long-running requests and it uses Thread.Abort implicitly to unload AppDomains.  On a heavily loaded system, AppDomains may be unloaded to relieve resource pressure.

I have a lengthy blog on this topic, but I have not been able to post it because it talks about undisclosed Whidbey features.  At some point (no later than shipping Beta1), you will find it at http://cbrumme.dev with a title of Hosting.  Until then, I’ll just mention that the Whidbey APIs support an escalation policy.  This is a declarative mechanism by which the host can express timeouts for normal finalization, normal AppDomain unload, normal Abort attempts, etc.  In addition to timeouts, the escalation policy can indicate appropriate actions whenever these timeouts expire.  So a normal AppDomain unload could (for example) be escalated to a rude AppDomain unload or a normal process exit or a rude process exit.

The distinction between polite/normal and rude involves several aspects beyond finalization.  If we just consider finalization, polite/normal means that we execute both normal and critical finalization.  Contrast this with a rude scenario where we will ignore the normal finalizers, which are discarded, and only execute the critical finalizers.  As you might expect, a similar distinction occurs between executing normal exception backout on threads, vs. restricting ourselves to any backout that is associated with CERs.

This allows a host to avoid solving the halting problem when performing normal finalization and exception backout, without putting the process at risk with respect to (critical) resource leakage or inconsistent state.
