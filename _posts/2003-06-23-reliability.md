---
layout: post
title: Reliability
permalink: reliability
date: 2003-06-23 12:51:00.000000000 -07:00
status: publish
type: post
published: true
---

I’ve been putting off writing this blog, not just because I’m on vacation in Maui and have far more tempting things to do.  It’s because one of my blogs has already been used on Slashdot as evidence that Windows cannot scale and won’t support distributed transactions (http://slashdot.org/comments.pl?sid=66598&cid=6122733), despite the fact that Windows scales well and does support distributed transactions.  So I’m nervous that this new blog will be quoted somewhere as evidence that managed applications cannot be reliable.

The fact is that there are a lot of robust managed applications out there.  During V1 of .NET, we all ran a peer-to-peer application called Terrarium.  This could run as a background application and would become a screen saver during periods of inactivity.  Towards the end of the release, I was running a week at a time without incident.  The only reason for recycling the process after a week was to switch to a newer CLR so it could be tested.

Each team ran their own stress suite in their own labs on dedicated machines.  And many teams would “borrow” machines from team members at night, to get even more machine-hours of stress coverage.  These stress runs are generally more stressful than normal applications.  For example, the ASP.NET team would put machines under high load with a mix of applications in a single worker process.  They would then recycle various AppDomains in that worker process every two or three minutes.  The worker process was required to keep running indefinitely with no memory growth, with no change in response time for servicing requests, and with no process recycling.  This simulates what happens if you update individual applications of a web site over an extended period of time.

Another example of stress was our GC Stress runs.  We would run our normal test suites in a mode where a GC was triggered on every thread at every point that a GC would normally be tolerated.  This includes a GC at every machine instruction of JITted code.  Each GC was forced to compact so that stale references could be detected.

We also have a “threaded stress” which tries to break loose as many race conditions in the CLR as possible by throwing many threads at each operation.

Our stress efforts are getting better over time.  The dev lead for the 64-bit effort recently told me that we’ve already had more 64-bit process starts in our lab than all of the 32-bit process starts during the 5 years of building V1 and V1.1.  We’ve got a very large (and very noisy) lab that is crammed with 64-bit boxes that are constantly running every test that we can throw at them.

Having said all that, CLR reliability in V1 and V1.1 still falls far short of where we would like it to be.  When these releases of the CLR encounter a serious problem, we “fail fast” and terminate the process.  Examples of serious problems include:

1. ExecutionEngineException
2. An Access Violation inside mscorwks.dll or mscoree.dll (except in a few specific bits of code, like the write barrier code, where AVs are converted into normal NullReferenceExceptions).
3. A corrupt GC heap
4. Stack overflow
5. Out of memory

The first three of the above examples are legitimate reasons for the process to FailFast.  They represent serious bugs in the CLR, or serious bugs in (highly trusted / unsafe) portions of the frameworks and the application.  It’s probably a security risk to continue execution under these circumstances, because it’s easy to imagine cases where type safety or other invariants have been violated.

But the last two cases (stack overflow and memory exhaustion) are a different matter.  In a perfect world – i.e. some future version of our platform – these resource errors should be handled more gracefully.  This means that the CLR should be hardened to tolerate them and the managed application should be able to trap these conditions and handle them.

There’s a lot of work involved in getting there.  I want to explain some of the complexity that’s involved.  But first I would like to point out why the current situation isn’t as bad as it seems.

For example, ASP.NET is able to pursue 100% reliability without worrying too much about resource errors.  That’s because ASP.NET can use AppDomain recycling and process recycling to avoid gradual “decay” of the server process.  Even if the server is leaking resources at a moderate rate, recycling will reclaim those resources.  And, if a server application is highly stack intensive, it can be run with a larger stack or it can be rewritten to use iteration rather than recursion.

And for client processes, it’s historically been the case that excessive paging occurs before actual memory exhaustion.  Since performance completely tanks when we thrash virtual memory, the user often kills the process before the CLR’s FailFast logic even kicks in.  In a sense, the human is proactively recycling the process the same way ASP.NET does.

This stopped being the case for server boxes some time ago.  It’s often the case that server boxes have enough physical memory to back the entire 2 or 3 GB of user address space in the server process.  Even when there isn’t quite this much memory, memory exhaustion often means address space exhaustion and it occurs before any significant paging has occurred.

This is increasingly the case for client machines, too.  It’s clear that many customers are bumping up against the hard limits of 32-bit processing.

Anyway, back to stack overflow & memory exhaustion errors.  These are both resource errors, similar to the inability to open another socket, create another brush, or connect to another database.  However, on the CLR team we categorize them as “asynchronous exceptions” rather than resource errors.  The other common asynchronous exception is ThreadAbortException.  It’s clear why ThreadAbortException is asynchronous: if you abort another thread, this could cause it to throw a ThreadAbortException at any machine instruction in JITted code and various other places inside the CLR.  In that sense, the exception occurs asynchronously to the normal execution of the thread.

> (In fact, the CLR will currently induce a ThreadAbortException while you are executing exception backout code like catch clauses and finally blocks.  Sure, we’ll reliably execute your backout clauses during the processing of a ThreadAbortException – but we’ll interrupt an existing exception backout in order to induce a ThreadAbortException.  This has been a source of much confusion.  Please don’t nest extra backout clauses in order to protect your code from this behavior.  Instead, you should assume a future version of the CLR will stop inducing aborts so aggressively.)

Now why would we consider stack overflow & memory exhaustion to be asynchronous?  Surely they only occur when the application calls deeper into its execution or when it attempts to allocate memory?  Well, that’s true.  But unfortunately the extreme virtualization of execution that occurs with managed code works against us here.  It’s not really possible for the application to predict all the places that the stack will be grown or a memory allocation will be attempted.  Even if it were possible, those predictions would be version-brittle.  A different version of the CLR (or an independent implementation like Mono, SPOT, Rotor or the Compact Frameworks) will certainly behave differently.

Here are some examples of memory allocations that might not be obvious to a managed developer:

* Implicit boxing occurs in some languages, causing value types to be instantiated on the heap.
* Class constructor (.cctor) methods are executed by the CLR prior to the first use of a class.
* In the future, JITting might occur at a finer granularity than a method.  For example, a rarely executed basic block containing a ‘throw’ clause might not be JITted until first use.
* Although we chose to remove this from our V1 product, the CLR used to discard code and re-JIT it even during return paths.
* Class loading can be delayed until the first use of a class.
* For domain-neutral code, the storage for static fields is duplicated in each AppDomain.  Some versions of the CLR have allocated this storage lazily, on first access.
* Operations on MarshalByRefObjects must sometimes be remoted.  This requires us to allocate during marshaling and unmarshaling.  Along the same lines, casting a ComObject might cause a QueryInterface call to unmanaged code.
* Accessing the Type of an instance, or accessing the current Thread, or accessing various other environmental state might cause us to lazily materialize that state.
* Security checks are implicit to many operations.  These generally involve instantiation.
* Strings are immutable.  Many “simple” string operations must allocate as a consequence.
* Future versions of the CLR might delay allocation of portions of an instance for better cache effects.  This already happens for some state, like an instance’s Monitor lock and – in some versions and circumstances – its hash code.
* VTables are a space-inefficient mechanism for dispatching virtual calls and interface calls.  Other popular techniques involve caching dispatch stubs which are lazily created.

The above is a very partial list, just to give a sense of how unpredictable this sort of thing is.  Also, any dynamic memory allocation attempt might be the one that drives the system over the edge, because the developer doesn’t know the total memory available on the target system, and because other threads and other processes are asynchronously competing for that same unknown pool.

But a developer doesn’t have to worry about other threads and processes when he’s considering stack space.  The total extent of the stack is reserved for himf when the thread is created.  And he can control how much of that reservation is actually committed at that time.

It should be obvious that it’s inadequate to only reserve some address space for the stack.  If the developer doesn’t also commit the space up front, then any subsequent attempt to commit a page of stack could fail because memory is unavailable.  In fact, Windows has the unfortunate behavior that committing a page of stack can fail even if plenty of memory is available.  This happens if the swap file needs to be extended on disk.  Depending on the speed of your disk, extending the swap file can take a while.  The attempt to commit your page of stack can actually time out during this period, giving you a spurious fault.  If you want a robust application, you should always commit your stack reservations eagerly.

So StackOverflowException is more tractable than OutOfMemoryException, in the sense that we can avoid asynchronous competition for the resource.  But stack overflows have their own special problems.  These include:

* The difficulty of predicting how much stack is enough.

  This is similar to the difficulty of predicting where and how large the memory allocations are in a managed environment.  For example, how much stack is used if a GC is triggered while you are executing managed code?  Well, if the code you are executing is “while (true) continue;” the current version of the CLR might need several pages of your stack.  That’s because we take control of your thread – which is executing an infinite loop – by rewriting its context and vectoring it to some code that throws an exception.  I have no idea whether the Compact Frameworks would require more or less stack for this situation.

* The difficulty of presenting an exception via SEH (Structured Exception Handling) when the thread is low on stack space.

  If you are familiar with stack overflow handling in Windows, you know that there is a guard bit.  This bit is set on all reserved but uncommitted stack pages.  The application must touch stack pages a page at a time, so that these uncommitted pages can be committed in order.  (Don’t worry – the JIT ensures that we never skip a page).  There are 3 interesting pages at the end of the stack reservation.  The very last one is always unmapped.  If you ever get that far, the process will be torn down by the operating system.  The one before that is the application’s buffer.  The application is allowed to execute all its stack-overflow backout using this reserve.  Of course, one page of reserve is inadequate for many modern scenarios.  In particular, managed code has great difficulty in restricting itself to a single page.

  The page before the backout reserve page is the one on which the application generates the stack overflow exception.  So you might think that the application gets two pages in which to perform backout, and indeed this can sometimes be the case.  But the memory access that triggers the StackOverflowException might occur in the very last bits of a page.  So you can really only rely on 1 page for your backout.

  A further requirement is that the guard bit must be restored on the final pages, as the thread unwinds out of its handling.  However, without resorting to hijacking some return addresses on the stack, it can be difficult to guarantee that the guard bits can be restored.  Failure to restore the guard bit means that stack overflow exceptions won’t be reliably generated on subsequent recursions.

* The inability of the CLR (and parts of the operating system!) to tolerate stack overflows at arbitrary places.

  I’m told that a stack overflow exception at just the wrong place in EnterCriticalSection or LeaveCriticalSection (I forget which) will leave the critical section in a corrupt state.  Whether or not this is true, I would be amazed if the user-mode portion of the operating system is completely hardened to stack overflow conditions.  And I know for a fact that the CLR has not been.

  In order for us to report all GC references, perform security checks, process exceptions and other operations, we need the stack to be crawlable at all times.  Unfortunately, some of the constructs we use for crawling the stack are allocated on the stack.  If we should take a stack overflow exception while erecting one of these constructs, we cannot continue managed execution.  Today, this situation drives us to our FailFast behavior.  In the future, we need to tighten up some invariants between the JIT and the execution engine, to avoid this catastrophe.  Part of the solution involves adding stack probes throughout the execution engine.  This will be tedious to build and maintain.

* Unwinding issues

  Managed exception handling is largely on the Windows SEH plan.  This means that filter clauses are called during the first pass, before any unwinding of the stack has occurred.  We can cheat a little here:  if there isn’t enough stack to call the managed filter safely, we can pretend that it took a nested stack overflow exception when we called it.  Then we can interpret this failure as “No, I don’t want to handle this exception.”

  When the first pass completes, we know where the exception will be caught (or if it will remain unhandled).  The finally and fault blocks and the terminating catch clause are executed during the second pass.  By the end of the second pass, we want to unwind the stack.  But should we unwind the stack aggressively, giving ourselves more and more stack for subsequent clauses to execute in?  If we are unwinding a StackOverflowException, we would like to be as aggressive as possible.  But when we are interoperating with C++ exceptions, we must delay the unwind.  That’s because the C++ exception is allocated on the stack.  If we unwind and reuse that portion of the stack, we will corrupt the exception state.

  (In fact, we’re reaching the edges of my understanding here.  I think that a C++ rethrow effectively continues the first pass of the initial exception, looking for a new handler further up the stack.  And I think that this means the stack cannot be unwound until we reach the end of a C++ catch clause.  But I’m constantly surprised by the subtleties of exception handling).

So it’s hard to predict where OutOfMemoryException, StackOverflowException and ThreadAbortException might occur.

But one day the CLR will harden itself so it can tolerate these exceptions without requiring a FailFast escape hatch.  And the CLR will do some (unspecified) fancy work with stack reserves and unwinding so that there’s enough stack available for managed code to process StackOverflowExceptions more like regular exceptions.

At that point, managed code could process asynchronous exceptions just like normal exceptions.

Where does that leave the application?  Unfortunately, it leaves it in a rather bad spot.  Consider what would happen if all application code had to be hardened against these asynchronous exceptions.  We already know that they can occur pretty much anywhere.  There’s no way that the application can pin-point exactly where additional stack or memory might be required – across all versions and implementations of the CLI.

As part of hardening, any updates the application makes to shared state must be transacted.  Before any protecting locks are released via exception backout processing, the application must guarantee that all shared state has been returned to a consistent state.  This means that the application must guarantee it can make either forward or backward process with respect to that state – without requiring new stack or memory resources.

For example, any .cctor method must preserve the invariant that either the class is fully initialized when the .cctor terminates, or that an exception escapes.  Since the CLR doesn’t support restartable .cctors, any exception that escapes will indicate that the class is “off limits” in this AppDomain.  This means that any attempt to use the class will receive a TypeInitializationException.  The inner exception indicates what went wrong with initializing this class in this AppDomain.  Since this might mean that the String class is unavailable in the Default AppDomain (which would be disastrous), we’re highly motivated to add support for restartable .cctors in a future release of the CLR.

Let’s forget about managed code for a moment, because we know that the way we virtualize execution makes it very difficult to predict where stack or memory resources might be required.  Instead, imagine that you are writing this “guaranteed forward or backward progress” code in unmanaged code.  I’ve done it, and I find it is very difficult.  To do it right, you need strict coding rules.  You need static analysis tools to check for conformance to those rules.  You need a harness that performs fault injection.  You need hours of directed code reviews with your brightest peers.  And you need many machine-years of stress runs.

It’s a lot of work, which is only warranted for those few pieces of code that need to be 100% robust.  Frankly, most applications don’t justify this level of effort.  And this really isn’t the sweet spot for managed development, which targets extremely high productivity.

So today it’s not possible to write managed code and still be 100% reliable, and most developers shouldn’t even try.  But our team has a broad goal of eventually supporting all unmanaged coding techniques in managed code (with some small epsilon of performance loss).  Furthermore, the CLR and frameworks teams already have a need for writing some small chunks of reliable managed code.  For example, we are trying to build some managed abstractions that guarantee resource cleanup.  We would like to build those abstractions in managed code, so we can get automatic support for GC reporting, managed exceptions, and all that other good stuff.  We’re prepared to invest all the care and effort necessary to make this code reliable – we just need it to be possible.

So I think you’ll see us delivering on this capability in the next release or two.  If I had to guess, I think you’ll see a way of declaring that some portion of code must be reliable.  Within that portion of code, the CLR won’t induce ThreadAbortExceptions asynchronously.  As for stack overflow and memory exhaustion, the CLR will need to ensure that sufficient stack and memory resources are available to execute that portion of code.  In other words, we’ll ensure that all the code has been JITted, all the classes loaded and initialized, all the storage for static fields is pre-allocated, etc.  Obviously the existence of indirections / polymorphism like virtual calls and interface calls makes it difficult for the CLR to deduce exactly what resources you might need.  We will need the developer to help out by indicating exactly what indirected resources must be prepared.  This will make the technique onerous to use and somewhat expensive in terms of working set.  In some ways, this is a good thing.  Only very limited sections of managed code should be hardened in this manner.  And most of the hardened code will be in the frameworks, where it belongs.

Here are my recommendations:

* Application code is responsible for dealing with synchronous application exceptions.  It’s everyone’s responsibility to deal with a FileNotFoundException when opening a file on disk.
* Application code is not responsible for dealing with asynchronous exceptions.  There’s no way we can make all our code bullet-proof when exceptions can be triggered at every machine instruction, in such a highly virtualized execution environment.
* Perhaps 0.01% of code will be especially hardened using not-yet-available techniques.  This code will be used to guarantee that all resources are cleaned up during an AppDomain unload, or to ensure that pending asynchronous operations never experience races when unloads occur.  We’re talking tricky “systems” operations.

Well, if the application isn’t responsible for dealing with asynchronous exceptions, who is?

That’s the job of the process host.  In the case of ASP.NET, it’s the piece of code that decides to recycle the process when memory utilization hits some threshold.  In the case of SQL Server, it’s the piece of code that decides whether to abort a transaction, unload an AppDomain, or even suspend all managed activity.  In the case of a random console application, it’s the [default] policy that might retain the FailFast behavior that you’ve seen in V1 and V1.1 of the CLR.  And if Office ever builds a managed version, it’s the piece of code I would expect to see saving edits and unloading documents when memory is low or exhausted.  (Don’t read anything into that last example.  I have no idea when/if there will be a managed Excel).  In other words, the process host knows how important the process is and what pieces can be discarded to achieve a consistent application state.  In the case of ASP.NET, the only reason to keep the process running is to avoid a pause while we spin up a new process.  In the case of SQL Server, the process is vitally important.  Those guys are chasing 5 9’s of availability.  In the case of a random console application, there’s a ton of state in the application that will be lost if the process goes down.  But there probably isn’t a unit of execution that we can discard, to get back to a consistent application state.  If the process is corrupt, it must be discarded.

In V1 & V1.1, it’s quite difficult for a process host to specify an appropriate reaction or set of reactions when an asynchronous exception occurs.  This will get much easier in our next release.

As usual, I don’t want to get into any specifics on exactly what we’re going to ship in the future.  But I do hope that I’ve painted a picture where the next release’s features will make sense as part of a larger strategy for dealing with reliability.
