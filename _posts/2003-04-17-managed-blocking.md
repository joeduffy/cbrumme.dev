---
layout: post
title: Managed blocking
permalink: managed-blocking
date: 2003-04-17 9:57:00.000000000 -07:00
status: publish
type: post
published: true
---

What’s the difference between WaitHandle.WaitOne/WaitAny/WaitAll and just PInvoke’ing to WaitForSingleObject or WaitForMultipleObjects directly?  Plenty.

There are several reasons why we prefer you to use managed blocking through WaitHandle or similar primitives, rather than calling out to the operating system via PInvoke.

**First, we can blur any platform differences for you**

Do you know the differences between Windows 95 and Windows Server 2003 when you have duplicate handles in the list you are waiting on?  You certainly shouldn’t have to!

**Second, we can do any pumping that is appropriate**

While a thread in a Single-Threaded Apartment (STA) blocks, we will pump certain messages for you.  Message pumping during blocking is one of the black arts at Microsoft.  Pumping too much can cause reentrancy that invalidates assumptions made by your application.  Pumping too little causes deadlocks.  Starting with Windows 2000, OLE32 exposes CoWaitForMultipleHandles so that you can pump “just the right amount.”  On lower operating systems, the CLR uses MsgWaitForMultipleHandles / PeekMessage / MsgWaitForMultipleHandlesEx and whatever else is available on that version of the operating system to try to mirror the behavior of CoWaitForMultipleHandles.  The net effect is that we will always pump COM calls waiting to get into your STA.  And any SendMessages to any windows will be serviced.  But most PostMessages will be delayed until you have finished blocking.

The degree of pumping that’s happening has been painfully tuned to be appropriate to WindowsForms, non-GUI console apps, ASP compatibility mode using an STA threadpool on the server, and all the other traditional STA scenarios.  However, in the future we know we’re going to be revisiting this.  The underlying operating system is evolving and there are some big changes underway in this area.  Believe me, you don’t want to be doing this stuff yourself.  The CLR should be insulating you from this pain.

**Third, the CLR can make wise decisions about activity**

The CLR threadpool monitors CPU utilization to guide its heuristics about thread injection and retirement.  It also notices GC activity, since there’s little reason to inject a thread that will immediately be suspended until a non-concurrent GC is complete.  The threadpool also notices whenever one of its threads is blocked or emerges from a blocking operation.  We can do this accurately if you use managed blocking.  If you PInvoke to unmanaged blocking services, everything is opaque.

**Fourth, we can ensure that your thread can be controlled**

The operating system provides a TerminateThread() service.  It should never be used under any circumstances.  It will corrupt the process.  The CLR provides services like Thread.Abort and Thread.Interrupt.  They can take control of your thread in a reasonably safe manner.  By reasonably safe, I mean that the process and the CLR remain consistent.  Your application state might not remain consistent.  In particular, if a thread is Aborted while it is executing a .cctor method, I’ve explained in another blog how this leaves your class in an “off limits” situation.  Another example of this is that your thread might be Aborted in the middle of executing some backout code like a finally or catch clause.  Once again, your application state might be corrupt.

(We’re careful to allow finally and catch clauses to execute once an Abort has been induced on your thread.  But that’s subtly different from never inducing an Abort in the middle of a finally or catch execution).

Over time, we hope to provide ways for your application to remain consistent – even in the face of Thread.Abort and other asynchronous exceptions, including resource failures like OutOfMemoryException and StackOverflowException.

Until then, there are only two completely safe uses of Thread.Abort:

1. You can abort your own thread via Thread.CurrentThread.Abort.
2. You can perform an AppDomain.Unload, which internally uses Thread.Abort to unwind threads out of the doomed AppDomain.

The first usage is safe because the Abort isn’t induced asynchronously.  You are inducing it directly on your own thread – almost as if you had called “throw new ThreadAbortException();”

The second usage is safe because all the application state is being discarded after the thread has been Aborted.  That application state might be inconsistent, but it’s all going away anyway.

However, if you PInvoke to WaitForMultipleObject, then Thread.Abort is powerless.  We cannot take control of threads that are in unmanaged code.  The operating system provides no safe way to do this.  A thread in unmanaged code could be holding arbitrary locks (the OS loader lock and the OS heap lock are two particularly troublesome ones).

So there are several good reasons why you should favor managed blocking over a PInvoke to unmanaged blocking.  Examples of managed blocking are: 

* Thread.Join
* WaitHandle.WaitOne/WaitAny/WaitAll
* GC.WaitForPendingFinalizers
* Monitor.Enter if there is enough contention for us to give up on spinning and block

Thread.Sleep is a little unusual.  We can take control of threads that are inside this service.  But, following the tradition of Sleep on the underlying Windows operating system, we perform no pumping.

If you need to Sleep on an STA thread, but you want to perform the standard COM and SendMessage pumping, consider Thread.CurrentThread.Join(timeout) as a replacement.
