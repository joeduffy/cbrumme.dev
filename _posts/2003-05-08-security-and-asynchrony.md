---
layout: post
title: Security and Asynchrony
permalink: security-and-asynchrony
date: 2003-05-08 22:28:00.000000000 -07:00
status: publish
type: post
published: true
---

In a comment to my last ramble, about asynchronous execution and pinning, someone asked for advice on using Windows impersonation in a managed application.  Unfortunately, the managed platform currently has poor abstractions and infrastructure for controlling Windows identity, and indeed for most of the unmanaged Windows security system.  For example, the managed classes for WaitHandles and Streams lack overloads for specifying SECURITY_ATTRIBUTES.  It’s true that we have defined some classes like System.Security.Principal.WindowsIdentity and WindowsPrincipal, but I don’t think these classes add enough value in their current form.

For now, you might even decide to avoid the managed abstractions and PInvoke to the underlying OS services, like RevertToSelf and SetThreadToken.  Be aware that this technique won’t work well in a fiber-based environment like SQL Server.  In that world, a logical thread (i.e. fiber) might be switched to a different operating system thread after you PInvoke to initiate impersonation.  If a fiber switch does indeed happen at that time, a different logical thread will now execute inside your impersonated context.

We certainly understand the limitations of our current support and we’re working to provide better abstractions in a future release.

The reason for this poor support is perhaps obvious.  In managed code, the focus of security is Code Access Security, not operating system concepts like impersonation.  We put a lot of effort into capturing CAS state and propagating it automatically through asynchronous operations.  For example, if Thread 1 creates and starts a new managed Thread 2, the CAS stack information from Thread 1 is automatically captured and propagated to the base of Thread 2.  When you call the normal ThreadPool operations, a similar capture and propagation of stack evidence occurs.  A sophisticated and trusted client of the ThreadPool can trade off that implicit security for better performance, by using ‘unsafe’ operations like UnsafeQueueUserWorkItem and UnsafeWaitForSingleObject.  A similarly sophisticated and trusted client could PInvoke to CreateThread, to avoid attaching his CAS information to the new thread.

Why do we propagate the CAS information from one thread to another in this manner?

Well, System.Environment.Exit() can be used to terminate the current process.  This is considered a privileged operation, so it’s protected by a Demand for UnmanagedCodePermission.  (I can’t remember if it’s a FullDemand or a LinkDemand.  For the purposes of this blog, let’s pretend it’s a FullDemand).  Because of the demand, partially trusted code cannot call this API directly.  If it does attempt the call, the security system will examine the stack and discover that partially trusted code is involved in the operation.  A security exception will be thrown.

But what if the partially trusted code can find a delegate declaration with the same signature as Exit()?  There are plenty of fully trusted delegate declarations, like System.Threading.ThreadStart.  (I realize that ThreadStart doesn’t have quite the right signature for Environment.Exit, but you get the idea).  If the partially trusted code can form one of these delegates over the Exit() method and then queue the delegate for execution on the threadpool, it can mount a security attack.  That’s because a threadpool thread will now call Exit() and satisfy the security Demand.  An examination of the stack would not find any code from the partially trusted attacker.

We prevent this attack by capturing the stack of the partially trusted caller when he calls ThreadPool.QueueUserWorkItem.  Then when the stack crawl is initiated by the Demand on Exit(), we consider that captured stack.  We discover the partially trusted code on the captured stack and fail the Demand.

In addition to creating a thread or initiating a safe ThreadPool operation, we also capture and propagate CAS information in services like System.Windows.Forms.Control.BeginInvoke.

However, we do not capture and propagate CAS information for the most common asynchronous operation of them all – finalization.  I can give two reasons to rationalize this fact.

1. Finalization is intended for cleaning up resources rather than for arbitrary execution.  The body of the finalize method should be self-contained; it should be designed so it is not subject to re-purposing attacks.  For example, fully trusted code should never expose an object that will call through an arbitrary delegate from its Finalize() method.

2. The performance impact of capturing and propagating stack information on each finalizable object would be unacceptable.  It’s an unfortunate fact of life that performance and security are often at odds with each other.  The best we can hope for is to strike an appropriate balance between these competing needs.

What if you need to do something delicate in a Finalize() method?  More generally, what if you are building your own ThreadPool or your own queue of server requests?  (Of course, there are many good reasons for using our ThreadPool rather than writing your own, but let’s ignore this for a moment).  Ultimately, any array of objects that’s shared between two threads can be a scenario where the thread inserting into the array might need to propagate its CAS information to the thread that is removing objects from that array and operating on them.

The solution to this problem is for you to call System.Threading.Thread.GetCompressedStack() and SetCompressedStack() yourself.  Of course, you need to have a high level of privilege (probably ControlEvidence) before you can do this.  These APIs were not public in our V1 release, but they are publicly available in 1.1.

If you go this route, there is one important detail you should be aware of.  The current behavior of this API is to place the “attached” CAS compressed stack at the base of the target thread.  It is not inserted into the new thread’s stack at the current stack location.  For normal stack crawls, this detail won’t matter.  But if your stacks contain combinations of Deny, Assert and PermitOnly statements, then position is significant.  By considering these statements out of order – which is our current behavior – it’s theoretically possible to get different results.

For example, you might Assert and then pick up a request with a compressed stack which you install with a SetCompressedStack.  This is a questionable practice already, because you really shouldn’t execute arbitrary code inside the scope of an Assert.  You should try to contain the scope of an Assert as much as possible.  Along the same lines, I’m personally uncomfortable with applications that base their security on Deny or PermitOnly statements.  Such statements can always be trumped by a subsequent Assert.

Anyway, transferring a compressed stack is generally much more secure than not transferring the compressed stack.  So any concerns about subtle interactions with Assert, Deny & PermitOnly based on the order in which we consider the current thread’s stack and the transferred stack are secondary.

Incidentally, Get/SetCompressedStack has a nifty merging mechanism which can avoid some common overflow scenarios.  Imagine what happens if you queue an asynchronous read.  The API you call will capture your compressed stack and flow it through the threadpool.  When the threadpool uses one of its threads to call your completion, the caller’s CAS information is available as we have seen.  A perfectly reasonable thing to do in the completion callback is to initiate a new asynchronous read, and return.  Now rinse and repeat indefinitely.

In terms of the stacks of the operating system threads, they are all nicely unwound by virtue of performing asynchronous operations.  But in terms of the CAS compressed stacks, their growth is unbounded.  When we initiate the 1000’th asynchronous read, the prior 999 stacks are all being propagated along.  What makes this particularly painful is that at least 998 of those compressed stacks are completely identical!  The additional stacks typically convey no new security information.

Fortunately, the mechanism for capturing and merging compressed stacks contains a simple pattern recognizer.  In this sort of scenario, the pattern recognizer will discard any obvious redundancies.  The CAS information quickly finds a fixed point.

I’ve already pointed out that there’s a spectrum of asynchronous operations.  At one end of the spectrum, we have obviously asynchronous scenarios like Stream.BeginRead, ThreadPool.QueueUserWorkItem, Thread.Start and raising Events.  At the other end of the spectrum, we have subtly asynchronous scenarios like one thread calling through an object that was placed into a shared static reference by another thread.  Ultimately, if you have shared memory and multiple threads, you have the potential for asynchrony and security attacks.

This is troubling, because there isn’t a bright line between risky operations that need securing via techniques like transferred compressed stacks versus normal safe operations which don’t warrant the overhead of stack transfers.

One scenario that’s particularly troubling to our team is events.  What if we can find an event that’s raised by some fully trusted code with a signature that matches System.Environment.Exit()?  Well, we could wire up the fully trusted caller (the event source) to the fully trusted but dangerous Exit service (the event sink) using a fully trusted delegate of the appropriate signature.

At that point, we just need to wait for the event to fire and the process will terminate.  There is no partially trusted code on the stack.

We’ve discussed many ways to solve this problem.  Most of them have a clumsy programming model.  All of them have a significant performance impact.  None of them do a great job of solving all the attacks possible with indirect calls (i.e. non-Event usage of delegates, and indirections through well-known interface methods or virtual methods).

Indeed, Events are probably the least susceptible to attack of all the indirect call attacks.  That’s because almost all Events on our platform share an idiosyncratic signature of (Object sender, EventArgs args).  An attacker isn’t going to find a lot of powerful APIs like Exit that have the same signature.  Indeed, checking for dangerous methods with this sort of signature is just one of the many, many security audits that we perform throughout our frameworks before shipping a release.

Still, it’s definitely an area where we would like to do better, and where we shall continue to invest design effort.
