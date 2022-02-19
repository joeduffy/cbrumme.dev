---
layout: post
title: Unhandled exceptions
permalink: unhandled-exceptions
date: 2003-04-15 14:49:00.000000000 -07:00
status: publish
type: post
published: true
---

There are two kinds of threads executing inside managed code:  the ones we start in managed code and the ones that wander into the CLR.  The ones that started in managed code include all calls to Thread.Start(), the managed threadpool threads, and the Finalizer thread(s).

For all the threads we start in managed code, the CLR has its own exception backstop and nothing will leak out to the OS unhandled exception filter.  We can call the AppDomain.UnhandledException event from this backstop.

For the ones that wander into managed code, we are registered on the OS unhandled exception filter so we can call the AppDomain.UnhandledException from there.  Of course, different unmanaged components are registered in a rather random order on the OS unhandled exception filter.  Some of them chain nicely.  Others (like the VC6 filter) might decide to rip the process without chaining under certain circumstances.

So you are only completely assured of getting the AppDomain’s UnhandledException event on the managed threads.

Another subtlety is that you must register for this event in the Default AppDomain.  That’s because – by the time the exception is unhandled – the thread has unwound out to the default AppDomain.  That’s where all threads start executing and that’s where they eventually unwind to.  This is an unfortunate restriction for some scenarios, but it’s not clear whether it will ever be relaxed.

Finally, the CLR has some default policy for which unhandled exceptions should terminate the process and which ones should be swallowed.  Generally, unhandled exceptions on threadpool threads, the Finalizer thread(s) and similar “reusable” threads are swallowed.  We simply terminate the current unit of work and proceed to the next one.  Unhandled exceptions on the main thread of a managed executable will terminate the process.

Nobody particularly likes the defaults that were chosen.  But everyone seems to have conflicting opinions on what would have made better defaults.  And, at this point, nothing is likely to change.  The UnhandledException event is there so that you can install your own policy.  You can terminate the process, log the failure, trap to the debugger, swallow the exception or any other behavior.
