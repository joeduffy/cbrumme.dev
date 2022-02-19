---
layout: post
title: Threads, fibers, stacks and address space
permalink: threads-fibers-stacks
date: 2003-04-15 18:45:00.000000000 -07:00
status: publish
type: post
published: true
---

Every so often, someone tries to navigate from a managed System.Threading.Thread object to the corresponding ThreadId used by the operating system.

System.Diagnostic.ProcessThread exposes the Windows notion of threads.  In other words, the OS threads active in the OS process.

System.Threading.Thread exposes the CLR’s notion of threads.  These are logical managed threads, which may not have a strict correspondence to the OS threads.  For example, if you create a new managed thread but don’t start it, there is no OS thread corresponding to it.  The same is true if the thread stops running – the managed object might be GC-reachable, but the OS thread is long gone.  Along the same lines, an OS thread might not have executed any managed code yet.  When this is the case, there is no corresponding managed Thread object.

A more serious mismatch between OS threads and managed threads occurs when the CLR is driven by a host which handles threading explicitly.  Even in V1 of the CLR, our hosting interfaces reveal primitive support for fiber scheduling.  Specifically, look at ICorRuntimeHost’s LogicalThreadState methods.  But please don’t use those APIs – it turns out that they are inadequate for industrial-strength fiber support.  We’re working to get them where they need to be.

In a future CLR, a host will be able to drive us to map managed threads to host fibers, rather than to OS threads.  The CLR cooperates with the host’s fiber scheduler in such a way that many managed threads are multiplexed to a single OS thread, and so that the OS thread chosen for a particular managed thread may change over time.

When your managed code executes in such an environment, you will be glad that you didn’t confuse the notions of managed thread and OS thread.

When you are running on Windows, one key to good performance is to minimize the number of OS threads.  Ideally, the number of OS threads is the same as the number of CPUs – or a small multiple thereof.  But you may have to turn your application design on its head to achieve this.  It’s so much more convenient to have a large number of (logical) threads, so you can keep the state associated with each task on a stack.

When faced with this dilemma, developers sometimes pick fibers as the solution.  They can keep a large number of cooperatively scheduled light-weight fibers around, matching the number of server requests in flight.  But at any one time only a small number of these fibers are actively scheduled on OS threads, so Windows can still perform well.

SQL Server supports fibers for this very reason.

However, it's hard to imagine that fibers are worth the incredible pain in any but the most extreme cases.  If you already have a fiber-based system that wants to run managed code, or if you’re like SQL Server and must squeeze that last 10% from a machine with lots of CPUs, then the hosting interfaces will give you a way to do this.  But if you are thinking of switching to fibers because you want lots of threads in your process, the work involved is enormous and the gain is slight.

Instead, consider techniques where you might keep most of your threads blocked.  You can release some of those threads based on CPU utilization dropping, and then use various application-specific techniques to get them to re-block if you find you have released too many.  This kind of approach avoids the rocket science of non-preemptive scheduling, while still allowing you to have a larger number of threads than could otherwise be efficiently scheduled by the OS.

Of course, the very best approach is to just have fewer threads.  If you schedule your work against the thread pool, we'll try to achieve this on your behalf.  Our threadpool will pay attention to CPU utilization, managed blocking, garbage collections, queue lengths and other factors – then make sensible dynamic decisions about how many work items to execute concurrently.  If that’s what you need, stay away from fibers.

If you have lots of threads or fibers, you may have to reduce your default stack size.  On Windows, applications get 2 GB of address space.  With a default stack size of 1 MB, you will run out of user address space just before 2000 threads.  Clearly that’s an absurd number of threads.  But it’s still the case that with a high number of threads, address space can quickly become a scarce resource.

On old versions of Windows, you controlled the stack sizes of all the threads in a process by bashing a value in the executable image.  Starting with Windows XP and Windows Server 2003, you can control it on a per-thread basis.  However, this isn’t exposed directly because:

1. It is a recent addition to Windows.

2. It’s not a high priority for non-EXE’s to control their stack reservation, since there are generally few threads and lots of address space.

3. There is a work-around.

The work-around is to PInvoke to CreateThread, passing a Delegate to a managed method as your LPTHREAD_START_ROUTINE.  Be sure to specify STACK_SIZE_PARAM_IS_A_RESERVATION in the CreationFlags.  This is clumsy compared to calling Thread.Start(), but it works.

Incidentally, there’s another way to deal with the scarce resource of 2 GB of user address space per process.  You can boot the operating system with the /3GB switch and – starting with the version of the CLR we just released – any managed processes marked with IMAGE_FILE_LARGE_ADDRESS_AWARE can now take advantage of the increased user address space.  Be aware that stealing all that address space from the kernel carries some real costs.  You shouldn’t be running your process with 3 GB of user space unless you really need to.

The one piece of guidance from all of the above is to reduce the number of threads in your process by leveraging the threadpool.  Even client applications should consider this, so they can work well in Terminal Server scenarios where a single machine supports many attached clients.
