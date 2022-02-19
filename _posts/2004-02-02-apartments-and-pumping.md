---
layout: post
title: Apartments and Pumping in the CLR
permalink: apartments-and-pumping
date: 2004-02-02 11:52:00.000000000 -07:00
status: publish
type: post
published: true
---

I’ve already written the much-delayed blog on Hosting, but I can’t post it yet because it mentions a couple of new Whidbey features, which weren’t present in the PDC bits.  Obviously Microsoft doesn’t want to make product disclosures through my random blog articles.

I’m hoping this will be sorted out in another week or two.

While we’re waiting, I thought I would talk briefly(!) about pumping and apartments.  The CLR made some fundamental decisions about OLE, thread affinity, reentrancy and finalization.  These decisions have a significant impact on program correctness, server scalability, and compatibility with legacy (i.e. unmanaged) code.  So this is going to be a blog like the one on Shutdown from last August (see http://cbrumme.dev/startup-shutdown).  There will be more detail than you probably care to know about one of the more frustrating parts of the Microsoft software stack.

First, an explanation of my odd choice of terms.  I’m using OLE as an umbrella which includes the following pieces of technology:

* COM – the fundamental object model, like IUnknown and IClassFactory
* DCOM – remoting of COM using IDL, NDR pickling and the SCM
* Automation – IDispatch, VARIANT, Type Libraries, etc.
* Active/X – Protocols for controls and their containers 

Next, some disclaimers:

I am not and have never been a GUI programmer.  So anything I know about Windows messages and pumping is from debugging GUI applications, not from writing them.  I’m not going to talk about WM_PENCTL notifications or anything else that requires UI knowledge.

Also, I’m going to point out a number of problems with OLE and apartments.  The history of the CLR and OLE are closely related.  In fact, at one point COM+ 1.0 was known internally as COM98 and the CLR was known internally as COM99.  We had some pretty aggressive ship targets back then!

In general, I love OLE and the folks who work on it.  Although it is inappropriate for the Internet, DCOM is still the fastest and most enterprise-ready distributed object system out there.  In a few ways the architecture of .NET Remoting is superior to DCOM, but we never had the time or resources to even approach the engineering effort that has gone into DCOM.  Presumably Indigo will eventually change this situation.  I also love COM’s strict separation of contract from implementation, the ability to negotiate for contracts, and so much more.

The bottom line is that OLE has had at least as much impact on Microsoft products and the industry, in its day, as .NET is having now.

But, like anything else, OLE has some flaws.  In contrast to the stark architectural beauty of COM and DCOM, late-bound Automation is messy.  At the time this was all rolled out to the world, I was at Borland and then Oracle.  As an outsider, it was hard for me to understand how one team could have produced such a strange combination.

Of course, Automation has been immensely successful – more successful than COM and DCOM.  My aesthetic taste is clearly no predictor of what people want.  Generally, people want whatever gets the job done, even if it does so in an ad hoc way.  And Automation has enabled an incredible number of application scenarios.

**Apartments**

If there’s another part of OLE that I dislike, it’s Single Threaded Apartments.  Presumably everyone knows that OLE offers three kinds of apartments:

<ins>Single Threaded Apartment (STA)</ins> – one affinitized thread is used to call all the objects residing in the apartment.  Any call on these objects from other threads must perform cross-thread marshaling to this affinitized thread, which dispatches the call.  Although a process can have an arbitrary number of STAs (with a corresponding number of threads), most client processes have a single Main STA and the GUI thread is the affinitized thread that owns it.

<ins>Multiple Threaded Apartment (MTA)</ins> – each process has at most one MTA at a time.  If the current MTA is not being used, OLE may tear it down.  A different MTA will be created as necessary later.  Most people think of the MTA as not having thread affinity.  But strictly speaking it has affinity to a group of threads.  This group is the set of all the threads that are not affinitized to STAs.  Some of the threads in this group are explicitly placed in the MTA by calling CoInitializeEx.  Other threads in this group are implicitly in the MTA because the MTA exists and because these threads haven’t been explicitly placed into STAs.  So, by the strict rules of OLE, it is not legal for STA threads to call on any objects in the MTA.  Instead, such calls must be marshaled from the calling STA thread over to one of the threads in the MTA before the call can legally proceed.

<ins>Neutral Apartment (NA)</ins> – this is a recent invention (Win2000, I think).  There is one NA in the process.  Objects contained in the NA can be called from any thread in the process (STA or MTA threads).  There are no threads associated with the NA, which is why it isn’t called NTA.  Calls into NA objects can be relatively efficient because no thread marshaling is ever required.  However, these cross-apartment calls still require a proxy to handle the transition between apartments.  Calls from an object in the NA to an object in an STA or the MTA might require thread marshaling.  This depends on whether or not the current thread is suitable for calling into the target object.  For example, a call from an STA object to an NA object and from there to an MTA object will require thread marshaling during the transition out of the NA into the MTA.

**Threading**

The MTA is effectively a free-threaded model.  (It’s not quite a free-threaded model, because STA threads aren’t strictly allowed to call on MTA objects directly).  From an efficiency point of view, it is the best threading model.  Also, it imposes the least semantics on the application, which is also desirable.  The main drawback with the MTA is that humans can’t reliably write free-threaded code.

Well, a few developers can write this kind of code if you pay them lots of money and you don’t ask them to write very much.  And if you code review it very carefully.  And you test it with thousands of machine hours, under very stressful conditions, on high-end MP machines like 8-ways and up.  And you’re still prepared to chase down a few embarrassing race conditions once you’ve shipped your product.

But it’s not a good plan for the rest of us.

The NA model is truly free-threaded, in the sense that any thread in the process can call on these objects.  All such threads must still transition through a proxy layer that maintains the apartment boundary.  But within the NA all calls are direct and free-threaded.  This is the only apartment that doesn’t involve thread affinity.

Although the NA is free-threaded, it is often used in conjunction with a lock to achieve rental threading.  The rental model says that only one thread at a time can be active inside an object or a group of objects, but there is no restriction on which thread this might be.  This is efficient because it avoids thread marshaling.  Rather than marshaling a call from one thread to whatever thread is affinitized to the target objects, the calling thread simply acquires the lock (to rent the context) and then completes the call on the current thread.  When the thread returns back out of the context, it releases the lock and now other threads can make calls.

If you call out of a rental context into some other object (as opposed to the return pathway), you have a choice.  You can keep holding the lock, in which case other threads cannot rent the context until you fully unwind.  In this mode, the rental context supports recursion of the current thread, but it does not support reentrancy from other threads.  Alternatively, the thread could release the lock when it calls out of the rental context, in which case it must reacquire the lock when it unwinds back and returns to the rental context.  In this mode, the rental context supports full reentrancy.

Throughout this blog, we’ll be returning to this fundamental decision of whether to support reentrancy.  It’s a complex issue.

If only recursion is supported on a rental model, it’s clear that this is a much more forgiving world for developers than a free-threaded model.  Once a thread has acquired the rental lock, no other threads can be active in the rented objects until the lock has been released.  And the lock will not be released until the thread fully unwinds from the call into the context.

Even with reentrancy, the number of places where concurrency can occur is limited.  Unless the renting thread calls out of the context, the lock won’t be released and the developer knows that other threads aren’t active within the rented objects.  Unfortunately, it might be hard for the developer to know all the places that call out of the current context, releasing the lock.  Particularly in a componentized world, or a world that combines application code with frameworks code, the developer can rarely have sufficient global knowledge.

So it sounds like limiting a rental context to same-thread recursion is better than allowing reentrancy during call outs, because the developer doesn’t have to worry about other threads mutating the state of objects in the rental context.  This is true.  But it also means that the resulting application is subject to more deadlocks.  Imagine what can happen if two rental contexts are simultaneously making calls to each other.  Thread T1 holds the lock to rent context C1.  Thread T2 holds the lock to rent context C2.  If T1 calls into C2 just as T2 calls into C1, and we are on the recursion plan, we have a classic deadlock.  Two locks have been taken in different sequences by two different threads.  Alternatively, if we are on a reentrancy plan, T1 will release the lock for C1 before contending for the lock on C2.  And T2 will release the lock for C2 before contending for the lock on C1.  The deadlock has been avoided, but T1 will find that the objects in C1 have been modified when it returns.  And T2 will find similar surprises when it returns to C2.

**Affinity**

Anyway, we now understand the free-threaded model of the MTA and NA and we understand how to build a rental model on top of these via a lock.  How about the single-threaded affinitized model of STAs?  It’s hard to completely describe the semantics of an STA, because the complete description must incorporate the details of pages of OLE pumping code, the behavior of 3rd party IMessageFilters, etc.  But generally an STA can be thought of as an **affinitized rental context** with **reentrancy** and **strict stacking**.  By this I mean:

* It is **affinitized rental** because all calls into the STA must marshal to the correct thread and because only one logical call can be active in the objects of the apartment at any time.  (This is necessarily the case, since there is only ever one thread).
* It has **reentrancy** because every callout from the STA thread effectively releases the lock held by the logical caller and allows other logical callers to either enter or return back to the STA.
* It has **strict stacking** because one stack (the stack of the affinitized STA thread) is used to process all the logical calls that occur in the STA.  When these logical calls perform a callout, the STA thread reentrantly picks up another call in, and this pushes the STA stack deeper.  When the first callout wants to return to the STA, it must wait for the STA thread’s stack to pop all the way back to the point of its own callout.

That point about strict stacking is a key difference between true rental and the affinitized rental model of an STA.  With true rental, we never marshal calls between threads.  Since each call occurs on its own thread, the pieces of stack for different logical threads are never mingled on an affinitized thread’s actual stack.  Returns back into the rental context after a callout can be processed in any order.  Returns back into an STA after a callout must be processed in a highly constrained order.

We’ve already seen a number of problems with STAs due to thread affinity, and we can add some more.  Here’s the combined list:

1. Marshaling calls between threads is expensive, compared to taking a lock.

2. Processing returns from callouts in a constrained fashion can lead to inefficiencies.  For instance, if the topmost return isn’t ready for processing yet, should the affinitized thread favor picking up a new incoming call (possibly leading to unconstrained stack growth) or should it favor waiting for the topmost return to complete (possibly idling the affinitized thread completely and conceivably resulting in deadlocks).

3. Any conventional locks held by an affinitized thread are worthless.  The affinitized thread is processing an arbitrary number of logical calls, but a conventional lock (like an OS CRITICAL_SECTION or managed Monitor) will not distinguish between these logical calls.  Instead, all lock acquisitions are performed by the single affinitized thread and are granted immediately as recursive acquisitions.  If you are thinking of building a more sophisticated lock that avoids this issue, realize that you are making that classic reentrancy vs. deadlock decision all over again.

4. Imagine a common server situation.  The first call comes in from a particular client, creates a few objects (e.g. a shopping cart) and returns.  Subsequent calls from that client manipulate that initial set of objects (e.g. putting some items into the shopping cart).  A final call checks out the shopping cart, places the order, and all the objects are garbage collected.  Now imagine that all those objects are affinitized to a particular thread.  As a consequence, the dispatch logic of your server must ensure that all calls from the same client are routed to the same thread.  And if that thread is busy doing other work, the dispatch logic must delay processing the new request until the appropriate affinitized thread is available.  This is complicated and it has a severe impact on scalability.

5. STAs must pump.  (How did I get this far without mentioning pumping?)

6. Any STA code that assumed a single-threaded world for the process, rather than just for the apartment, might not pump.  Such code breaks when we introduce the CLR into the process, as we will see.

**Failure to Pump**

Let’s look at those last two bullet points in more detail.  When your STA thread is doing nothing else, it needs to be checking to see if any other threads want to marshal some calls into it.  This is done with a Windows message pump.  If the STA thread fails to pump, these incoming calls will be blocked.  If the incoming calls are GUI SendMessages or PostMessages (which I think of as synchronous or asynchronous calls respectively), then failure to pump will produce an unresponsive UI.  If the incoming calls are COM calls, then failure to pump will result in calls timing out or deadlocking.

If processing one incoming call is going to take a while, it may be necessary to break up that processing with intermittent visits to the message pump.  Of course, if you pump you are allowing reentrancy to occur at those points.  So the developer loses all his wonderful guarantees of single threading.

Unfortunately, there’s a whole lot of STA code out there which doesn’t pump adequately.  For the most part, we see this in non-GUI applications.  If you have a GUI application that isn’t pumping enough, it’s obvious right there on the screen.  Those bugs tend to get fixed.

For non-GUI applications, a failure to pump may not be noticed in unmanaged code.  When that code is moved to managed (perhaps by re-compiling some VB6 code as VB.NET), we start seeing bugs.  Let’s look at a couple of real-world cases that we encountered during V1 of the CLR and how the lingering effects of these cases are still causing major headaches for managed developers and for Microsoft Support.  I’ll describe a server case first, and then a client case.

**ADO and ASP Compatibility Mode**

ADO.NET and ASP.NET are a winning combination.  But ASP.NET also supports an ASP compatibility mode.  In this mode, legacy ASP pages can be served up by the managed ASP.NET pipeline.  Such pages were written before we invented our managed platform, so they use ADO rather than ADO.NET for any data access.  Also, in this mode the DCOM threadpool is used rather than the managed System.Threading.ThreadPool.  Although all the threads in the managed ThreadPool are explicitly placed in the MTA (as you might hope and expect), the DCOM threadpool actually contains STA threads.

The purpose of this STA threadpool was to allow legacy STA COM objects in general, and VB6 objects in particular, to be moved from the client to the server.  The result suffers from the scaling problems I alluded to before, since requests are dispatched on up to 100 STA threads with careful respect for any affinity.  Also, VB6 has a variable scope which corresponds to “global” (I forget its name), but which is treated as per-thread when running on the server.  If there are more than 100 clients using a server, multiple clients will share a single STA thread based on the whims of the request dispatch logic.  This means that global variables are shared between sets of clients in a surprising fashion, based on the STA that they happen to correspond to.

A typical ASP page written in VBScript would establish a (hopefully pooled) database connection from ADO, query up a row, modify a field, and write the row back to the database.  Since the page was likely written in VB, any COM AddRef and Release calls on the ADO row and field value objects were supplied through the magic of the VB6 runtime.  This means they occur on the same thread and in a very deterministic fashion.

The ASP page contains no explicit pumping code.  Indeed, at no point was the STA actually pumped.  Although this is a strict violation of the rules, it didn’t cause any problems.  That’s because there are no GUI messages or inter-apartment COM calls that need to be serviced.

This technique of executing ASP pages on STAs with ADO worked fairly well – until we tried to extend the model to ASP.NET running in ASP compatibility mode.  The first problem that we ran into was that all managed applications are automatically multi-threaded.  For any application of reasonable complexity, there are sure to be at least a few finalizable objects.  These objects will have their Finalize methods called by one or more dedicated finalizer threads that are distinct from the application threads.

(It’s important that finalization occurs on non-application threads, since we don’t want to be holding any application locks when we call the Finalize method.  And today the CLR only has a single Finalizer thread, but this is an implementation detail.  It’s quite likely that in the future we will concurrently call Finalize methods on many objects, perhaps by moving finalization duties over to the ThreadPool.  This would address some scalability concerns with finalization, and would also allow us to make stronger guarantees about the availability of the finalization service).

Our COM Interop layer ensures that we almost only ever call COM objects in the correct apartment and context.  The one place where we violate COM rules is when the COM object’s apartment or context has been torn down.  In that case, we will still call IUnknown::Release on the pUnk to try to recover its resources, even though this is strictly illegal.  We’ve gone backwards and forwards on whether this is appropriate, and we provide a Customer Debug Probe so that you can detect whether this is happening in your application.

Anyway, let’s pretend that we absolutely always call the pUnk in the correct apartment and context.  In the case of an object living in an STA, this means that the Finalizer thread will marshal the call to the affinitized thread of that STA.  But if that STA thread is not pumping, the Finalizer thread will block indefinitely while attempting to perform the cross-thread marshaling.

The effect on a server is crippling.  The Finalizer thread makes no progress.  The number of unreleased pUnks grows without bounds.  Eventually some resource (usually memory) is exceeded and the process crashes.

One solution is to edit the original ASP page to pump the underlying STA thread that it is executing on.  A light-weight way to pump is to call Thread.CurrentThread.Join(0).  This causes the current thread to block until the current thread dies (which isn’t going to happen) or until 0 milliseconds have elapsed – whichever happens first.  I’ll explain later why this also performs some pumping and why this is a controversial aspect of the CLR.  A heavier-weight way to pump is to call GC.WaitForPendingFinalizers.  This not only performs pumping, but it also waits for the Finalization queue to drain.

If you are porting a page that produces a modest number of COM objects, doing a simple Join on each page may be sufficient.  If your page performs elaborate processing, perhaps creating an unbounded number of COM objects in a loop, then you may need to either add a Join within the loop or WaitForPendingFinalizers at the end of the page processing.  The only way to really know is to experiment with both techniques, measuring the growth of the Finalization queue and the impact on server throughput.

**ADO’s Threading Model**

There was another problem with using ADO from ASP.NET’s ASP compatibility mode.  Do you know what the threading model of ADO is?  Well, if you check the registry for some ADO CLSIDs on your machine, you may find them registered as ThreadingModel=Single or you may find them registered as ThreadingModel=Both.

If these classes are registered as Single, OLE will carefully ensure that their instances can only be called from the thread that they were created on.  This implies that the objects can assume a single-threaded view of the world and they do not need to be written in a thread-safe manner.  If these classes are registered as Both, OLE will ensure that their instances are only called from threads in the right apartment.  But if that apartment is the MTA, these objects better have been written in a thread-safe manner.  For example, they had better be using InterlockedIncrement and Decrement, or an equivalent, for reference counting.

Unfortunately, the ADO classes are not thread-safe.  Strictly speaking, they should never be registered as anything but Single.  You may find them registered as Both on your machine because this improves scalability and throughput for some key scenarios.  And those key scenarios happen to limit themselves to “one thread at a time” because of how ASP and VB6 work.

In fact, the legacy ADO classes don’t even support single-threaded access if there is reentrancy.  They will randomly crash when used in this manner (and this is exactly the manner in which ADO was driven in the early days of V1).  Here are the steps:

1. The page queries up an ADO row object, which enters managed code via COM Interop as an RCW (runtime-callable wrapper).
2. By making a COM call on this RCW, the page navigates to a field value.  This field value also enters managed code via COM Interop as an RCW.
3. The page now makes a COM call via ADO which results in a call out to the remote database.  At this point, the STA thread is pumped by the DCOM remote call.  Since this is a remote call, it’s going to take a while before it returns.
4. The garbage collector decides that it’s time to collect.  At this point, the RCW for the field value is still reachable and is reported.  The RCW for the row object is no longer referenced by managed code and is collected.
5. The Finalizer thread notices that the pUnk underlying the row’s RCW is no longer in use, and it makes the cross-apartment call from the Finalizer thread’s apartment (MTA) to the ADO row object’s apartment (STA).
6. Recall that the STA thread is pumping for the duration of the remote database call (#3 above).  It picks up the cross-thread call from the Finalizer (#5 above) and performs the Release on the Row object.  This is the final Release and ADO deletes the unmanaged Row object from memory.  This logical call unwinds and the Finalizer thread is unblocked (hurray).  The STA thread returns to pumping.
7. The remote database call returns back to the server machine.  The STA thread picks it up from its pumping loop and returns back to the page, unwinding the thread.
8. The page now updates the field value, which involves a COM call to the underlying ADO object.
9. ADO crashes or randomly corrupts memory.

What happened?  The ADO developers made a questionable design decision when they implemented COM reference counting throughout their hierarchy.  The field values refer to their owning row object, but they don’t hold a reference count on that row.  Instead, they assume that the row will live as long as all of its associated field values.  And yet, whenever the application makes an ADO call on a field value, the field value will access that (hopefully present) row.

This assumption worked fine in the days of ASP and VB6.  So nobody even noticed the bug until the CLR violated those threading assumptions – without violating the underlying OLE rules, of course.

It was impractical to fix this by opening up ADO and rewriting the code.  There are many different versions of ADO in existence, and many products that distribute it.  Another option was to add GC.KeepAlive(row) calls at the bottom of each page, to extend the lifetime of the row objects until the field values were no longer needed.  This would have been a nightmare for Support.

Instead, the ADO team solved the problem for managed code with a very elegant technique.  (I invented it, so of course I think it was elegant).  They opened up the assembly that was created by TlbImp’ing ADO.  Then they added managed references from the RCWs of the field values to the RCWs of their owning rows.  These managed references are completely visible to the garbage collector.  Now the GC knows that if the field values are reachable then the row values must also be reachable.  Problem solved.

**No Typelib Registered**

Incidentally, we ran into another very common problem when we moved existing client or server COM applications over to managed code.  Whenever an application uses a COM object, it tries hard to match the thread of the client to the ThreadingModel of the server.  In other words, if the application needs to use a ThreadingModel=Main COM object, the application tries to ensure that the creating thread is in an STA.  Similarly, if the application needs to use a ThreadingModel=Free COM object, it tries to create this object from an MTA thread.  Even if a COM object is ThreadingModel=Both, the application will try to access the object from the same sort of thread (STA vs. MTA) as the thread that created the object.

One reason for doing this is performance.  If you can avoid an apartment transition, your calls will be much faster.  Another reason has to do with pumping and reentrancy.  If you make a cross-apartment call into an STA, the STA better be pumping to pick up your call.  And if you make a cross-apartment call out of an STA, your thread will start pumping and your application becomes reentrant.  This is a small dose of free-threading, and many application assumptions start to break.  A final reason for avoiding apartment transitions is that they often aren’t supported.  For instance, most ActiveX scenarios require that the container and the control are in the same STA.  If you introduce an apartment boundary (even between two STAs), bizarre cases like Input Synchronous messages stop working properly.

The net result is that a great many applications avoid using COM objects across apartment boundaries.  And this means that – even if that COM object is nominally marshalable across an apartment boundary – this often isn’t being tested.  So an application might install itself without ensuring that the typelib of the COM component is actually registered.

When the application is moved to managed code, developers are frustrated to see InvalidCastExceptions on the managed side.  A typical sequence is that they successfully ‘new’ the COM object, implying that the CoCreate returned a pUnk which was wrapped in an RCW.  Then when they cast it to one of the interfaces that they know is supported, a casting exception is thrown.  This casting exception is due to a QueryInterface call failing with E_NOINTERFACE.  Yet this HRESULT is not returned by the COM object, which does indeed support the interface.  Instead, it is returned by a COM apartment proxy which sits between the RCW and that COM object.  The COM apartment proxy is simply failing to marshal the interface across the apartment boundary – usually because the COM object is using the OLEAUT marshaler and the Typelib has not been properly registered.

This is a common failure, and it’s unfortunate that a generic E_NOINTERFACE doesn’t lead to better debuggability for this case.

Finally, I can’t help but mention that the COM Interop layer added other perturbations to many unmanaged COM scenarios that seemed to be working just fine.  Common perturbations from managed code include garbage collection, a Finalizer thread, strict conformance to OLE marshaling rules, and the fact that managed objects are agile with respect to COM apartments and COM+ contexts (unless they derive from ServicedComponent).

For instance, Trident required that all calls on its objects occur on the correct thread.  But Trident also had an extension model where 3rd party objects could be aggregated onto their base objects.  Unfortunately, the aggregator performed blind delegation to the 3rd party objects.  And – even more unfortunate – this blind delegation did not exclude QI’s for IMarshal.  Of course, managed objects implement IMarshal to achieve their apartment and context agility.  So if Trident aggregated a managed object as an extention, the containing Trident object would attempt to become partially agile in a very broken way.

Hopefully we found and dealt with most of these issues before we shipped V1.

**Not Pumping a Client**

I said I would describe two cases where non-pumping unmanaged code caused problems when we moved to managed code.  The above explains, in great detail, how ADO and ASP compatibility mode caused us problems on the server.  Now let’s look at the non-GUI client case.

We all know that a WinForms GUI client is going to put the main GUI thread into an STA.  And we know that there’s a lot of pumping in a GUI application, or else not much is going to show on the screen.

Assume for a moment that a Console application also puts its main thread into an STA.  If that main thread creates any COM objects via COM Interop, and if those COM objects are ThreadingModel=Main or Both, then the application better be pumping.  If it fails to pump, we’ll have exactly the same situation with our server running ASP compatibility mode.  The Finalizer thread won’t be able to marshal calls into the STA to Release any pUnks.

On a well-loaded server, that failure is quickly noticed by the developer or by the folks in operations.  But on a client, this might be just a mild case of constipation.  The rate of creation of finalizable objects may be low enough that the problem is never noticed.  Or it may be noticed as a gradual build up of resources.  If the problem is reported to Microsoft Support, the customer generally categorizes it as a garbage collection bug.

So what is the apartment of a Console application’s main thread?  Well, it depends.

If you build a Console application in Notepad, the main thread is likely to start off in the MTA.  If you build a Console application with Visual Studio, then if you pick C# or VB.NET your main thread is likely to be in an STA.  If you build a Console application with Visual Studio and you choose managed C++, your main thread is likely to be in an MTA for V1 or V1.1.  I think it’s likely to be in an STA for our next release.

Wow.  Why are we all over the place on this?  Mostly, it’s because there is no correct answer.  Either the developer is not going to use any COM objects in his Console application, in which case the choice doesn’t really matter, or the developer is going to use some COM objects and this should inform his decision.

For instance, if the developer will use COM objects with ThreadingModel=Main, he probably wants to put his main thread into an STA so he can use the COM objects directly without cross-thread marshaling and all the issues that this would imply.  This means he should also pump that thread, if there are other threads (like the Finalizer!) active in the process.  Alternatively, if the developer intends to use COM objects with ThreadingModel=Free, he probably wants to put his main thread in the MTA so he can access those objects directly.  Now he doesn’t need to pump, but he does need to consider the implications of writing free-threaded code.

Either way, the developer has some responsibility.

Unfortunately, the choice of a default is typically made by the project type that he selects in Visual Studio, or is based on the CLR’s default behavior (which favors MTA).  And realistically the subtleties of apartments and pumping are beyond the knowledge (or interest) of most managed developers.  Let’s face it: nobody should have to worry about this sort of thing.

**The Managed CoInitialize Mess**

There are three ways to select an apartment choice for the main thread of your Console application.  All three of these techniques have concerns associated with them.

1. You can place either an STAThreadAttribute or MTAThreadAttribute onto the main method.

2. You can perform an assignment to System.Threading.CurrentThread.ApartmentState as one of the first statements of your main method (or of your thread procedure if you do a Thread.Start).

3. You can accept the CLR’s default of MTA.

So what’s wrong with each of these techniques?

The first technique is the preferred method, and it works very well for C#.  After some tweaks to the VB.NET compiler before we shipped V1, it worked well for VB too.  Managed C++ still doesn’t properly support this technique.  The reason is that the entrypoint of a managed C++ EXE isn’t actually your ‘main’ routine.  Instead, it’s a method inside the C-runtime library.  That method eventually delegates to your ‘main’ routine.  But the CLR doesn’t scan through the closure of calls from the entrypoint when looking for the custom attribute that defines the threading model.  If the CLR doesn’t find it on the method that is the EXE’s entrypoint, it stops looking.  The net result is that your attribute is quietly ignored for C++.

I’m told that this will be addressed in Whidbey, by having the linker propagate the attribute from ‘main’ to the CRT entrypoint.  And indeed this is how the VB.NET compiler works today.

What’s wrong with the second technique?  Unfortunately, it is subject to a race condition.  Before the CLR can actually call your thread procedure, it may first call some module constructors, class constructors, AssemblyLoad notifications and AssemblyResolve notifications.  All of this execution occurs on the thread that was just created.  What happens if some of these methods set the thread’s ApartmentState before you get a chance?  What happens if they call Windows services like the clipboard that also set the apartment state?  A more likely scenario is that one of these other methods will make a PInvoke call that marshals a BSTR, SAFEARRAY or VARIANT.  Even these innocuous operations can force a CoInitializeEx on your thread and limit your ability to configure the thread from your thread procedure.

When you are developing your application, none of the above is likely to occur.  The real nightmare scenario is that a future version of the CLR will provide a JIT that inlines a little more aggressively, so some extra class constructors execute before your thread procedure.  In other words, you will ship an application that is balanced on a knife edge here, and this will become an App Compatibility issue for all of us.  (See http://cbrumme.dev/pdc-appcompat for more details on the sort of thing we worry about here).

In fact, for the next release of the CLR we are seriously considering making it impossible to set the apartment state on a running thread in this manner.  At a minimum, you should expect to see a Customer Debug Probe warning of the risk here.

And the third technique from above has a similar problem.  Recall that threads in the MTA can be explicitly placed there through a CoInitializeEx call, or they can be implicitly treated as being in the MTA because they haven’t been placed into an STA.  The difference between these two cases is significant.

If a thread is explicitly in the MTA, any attempt to configure it as an STA thread will fail with an error of RPC_E_CHANGED_MODE.  By contrast, if a thread is implicitly in the MTA it can be moved to an STA by calling CoInitializeEx.  This is more likely than it may sound.  If you attempt a clipboard operation, or you call any number of other Windows services, the code you call may attempt to place your thread in the STA.  And when you accept the CLR default behavior, it currently leaves the thread implicitly in the MTA and therefore is subject to reassignment.

This is another place where we are seriously considering changing the rules in the next version of the CLR.  Rather than place threads implicitly in the MTA, we are considering making this assignment explicit and preventing any subsequent reassignment.  Once again, our motivation is to reduce the App Compat risk for applications after they have been deployed.

Speaking of race conditions and apartments, the CLR has a nasty bug which was introduced in V1 and which we have yet to remove.  I’ve already mentioned that any threads that aren’t in STAs or explicitly in the MTA are implicitly in the MTA.  That’s not strictly true.  These threads are only in the MTA if there is an MTA for them to be in.

There is an MTA if OLE is active in the process and if at least one thread is explicitly in the MTA.  When this is the case, all the other unconfigured threads are implicitly in the MTA.  But if that one explicit thread should terminate or CoUninitialize, then OLE will tear down the MTA.  A different MTA may be created later, when a thread explicitly places itself into it.  And at that point, all the unconfigured threads will implicitly join it.

But this destruction and recreation of the MTA has some serious impacts on COM Interop.  In fact, any changes to the apartment state of a thread can confuse our COM Interop layer, cause deadlocks on downlevel platforms, and lead to memory leaks and violation of OLE rules.

Let’s look at how this specific race condition occurs first, and then I’ll talk about the larger problems here.

1. An unmanaged thread CoInitializes itself for the MTA and calls into managed code.
2. While in managed code, that thread introduces some COM objects to our COM Interop layer in the form of RCWs, perhaps by ‘new’ing them from managed code.
3. The CLR notices that the current thread is in the MTA, and realizes that it must “keep the MTA alive.”  We signal the Finalizer thread to put itself explicitly into the MTA via CoInitializeEx.
4. The unmanaged thread returns out to unmanaged code where it either dies or simply calls CoUninitialize.  The MTA is torn down.
5. The Finalizer thread wakes up and explicitly CoInitializes itself into the MTA.  Oops.  It’s too late to keep the original MTA alive and it has the effect of creating a new MTA.  At least this one will live until the end of the process.

As far as I know, this is the only race condition in the CLR that we haven’t fixed.  Why have we ignored it all these years?  First, we’ve never seen it reported from the field.  This isn’t so surprising when you consider that the application often shares responsibility for keeping the MTA alive.  Many applications are aware of this obligation and – if they use COM – they always keep an outstanding CoInitialize on one MTA thread so the apartment won’t be torn down.  Second, I generally resist fixing bugs by adding inter-thread dependencies.  It would be all too easy to create a deadlock by making step 3 wait for the Finalizer thread to CoInitialize itself, rather than just signaling it to do so.  This is particularly true since the causality of calls from the Finalizer to other threads is often opaque to us, as I’ll explain later.  And we certainly don’t want to create a dedicated thread for this purpose.  Dedicated threads have a real impact on Terminal Server scenarios, where the cost of one thread in a process is multiplied by all the processes that are running.  Even if we were prepared to pay this cost, we would want to create this thread lazily.  But synchronizing with the creation of another thread is always a dangerous proposition.  Thread creation involves taking the OS loader lock and making DLL_THREAD_ATTACH notifications to all the DllMain routines that didn’t explicitly disable these calls.

The bottom line is that the fix is expensive and distasteful.  And it speaks to a more general problem, where many different components in a process may be individually spinning up threads to keep the MTA from being recycled.  A better solution is for OLE to provide an API to keep this apartment alive, without requiring all those dedicated threads.  This is the approach that we are pursuing for the long term.

In our general cleanup of the CLR’s treatment of CoInitialize, we are also likely to change the semantics of assigning the current thread’s ApartmentState to Unknown.  In V1 & V1.1 of the CLR, any attempt to set the state to Unknown would throw an ArgumentOutOfRangeException, so we’re confident that we can make this change without breaking applications.

If the CLR has performed an outstanding CoInitializeEx on this thread, we may treat the assignment to Unknown as a request to perform a CoUninitialize to reverse the operation.  Currently, the only way you can CoUninitialize a thread is to PInvoke to the OLE32 service.  And such changes to the apartment state are uncoordinated with the CLR.

Now why does it matter if the apartment state of a thread changes, without the CLR knowing?  It matters because:

1. The CLR may hold RCWs over COM objects in the apartment that is about to disappear.  Without a notification, we cannot legally release those pUnks.  As I’ve already mentioned, we break the rules here and attempt to Release anyway.  But it’s still a very bad situation and sometimes we will end up leaking.

2. The CLR will perform limited pumping of STA threads when you perform managed blocking (e.g. WaitHandle.WaitOne).  If we are on a recent OS, we can use the IComThreadingInfo interface to efficiently determine whether we should pump or not.  But if we are on a downlevel platform, we would have to call CoInitialize prior to each blocking operation and check for a failure code to absolutely determine the current state of the thread.  This is totally impractical from a performance point of view.  So instead we cache what we believe is the correct apartment state of the thread.  If the application performs a CoInitialize or CoUninitialize without informing us, then our cached knowledge is stale.  So on downlevel platforms we might neglect to pump an STA (which can cause deadlocks).  Or we may attempt to pump an MTA (which can cause deadlocks).

Incidentally, if you ever run managed applications under a diagnostic tool like AppVerifier, you may see complaints from that tool at process shutdown that we have leaked one or more CoInitialize calls.  In a well-behaved application, each CoInitialize would have a balancing CoUninitialize.  However, most processes are not so well-behaved.  It’s typical for applications to terminate the process without unwinding all the threads of the process.  There’s a very detailed description of the CLR’s shutdown behavior at http://cbrumme.dev/startup-shutdown.

The bottom line here is that the CLR is heavily dependent on knowing exactly when apartments are created and destroyed, or when threads become associated or disassociated with those apartments.  But the CLR is largely out of the loop when these operations occur, unless they occur through managed APIs.  Unfortunately, we are rarely informed.  For an extreme example of this, the Shell has APIs which require an STA.  If the calling thread is implicitly in the MTA, these Shell APIs CoInitialize that calling thread into an STA.  As the call returns, the API will CoUnitialize and rip down the apartment.

We would like to do better here over time.  But there are some pretty deep problems and most solutions end up breaking an important scenario here or there.

**Back to Pumping**

Enough of the CoInitialize mess.  I mentioned above that managed blocking will perform some pumping when called on an STA thread.

Managed blocking includes a contentious Monitor.Enter, WaitHandle.WaitOne, WaitHandle.WaitAny, GC.WaitForPendingFinalizers, our ReaderWriterLock and Thread.Join.  It also includes anything else in FX that calls down to these routines.  One noticeable place where this happens is during COM Interop.  There are pathways through COM Interop where a cache miss occurs on finding an appropriate pUnk to dispatch a call.  At those points, the COM call is forced down a slow path and we use this as an opportunity to pump a little bit.  We do this to allow the Finalizer thread to release any pUnks on the current STA, if the application is neglecting to pump.  (Remember those ASP Compat and Console client scenarios?)  This is a questionable practice on our part.  It causes reentrancy at a place where it normally could never occur in pure unmanaged scenarios.  But it allows a number of applications to successfully run without clogging up the Finalizer thread.

Anyway, managed blocking does not include PInvokes directly to any of the OS blocking services.  And keep in mind that if you PInvoke to the OS blocking services directly, the CLR will no longer be able to take control of your thread.  Operations like Thread.Interrupt, Thread.Abort and AppDomain.Unload will be indefinitely delayed.

Did you notice that I neglected to mention WaitHandle.WaitAll in the list of managed blocking opeprations?  That’s because we don’t allow you to call WaitAll from an STA thread.  The reason is rather subtle.  When you perform a pumping wait, at some level you need to call MsgWaitForMultipleObjectsEx, or a similar Msg* based variant.  But the semantics of a WAIT_ALL on an OS MsgWaitForMultipleObjectsEx call is rather surprising and not what you want at all.  It waits for all the handles to be signaled AND for a message to arrive at the message queue.  In other words, all your handles could be signaled and the application will keep blocking until you nudge the mouse!  Ugh.

We’ve toyed with some workarounds for this case.  For example, you could imagine spinning up an MTA thread and having it perform the blocking operation on the handles.  When all the handles are signaled, it could set another event.  The STA thread would do a WaitHandle.WaitOne on that other event.  This gives us the desired behavior that the STA thread wakes up when all handles are signaled, and it still pumps the message queue.  However, if any of those handles are “thread-owned”, like a Mutex, then we have broken the semantics.  Our sacrificial MTA thread now owns the Mutex, rather than the STA thread.

Another technique would be to put the STA thread into a loop.  Each iteration would ping the handles with a brief timeout to see if it could acquire them.  Then it would check the message queue with a PeekMessage or similar technique, and then iterate.  This is a terrible solution for battery-powered devices or for Terminal Server scenarios.  What used to be efficient blocking is now busily spinning in a loop.  And if no messages actually arrive, we have disturbed the fairness guarantees of the OS blocking primitives by pinging.

A final technique would be to acquire the handles one by one, using WaitOne.  This is probably the worst approach of all.  The semantics of an OS WAIT_ALL are that you will either get no handles or you will get all of them.  This is critical to avoiding deadlocks, if different parts of the application block on the same set of handles – but fill the array of handles in random order.

I keep saying that managed blocking will perform “some pumping” when called on an STA thread.  Wouldn’t it be great to know exactly what will get pumped?  Unfortunately, pumping is a black art which is beyond mortal comprehension.  On Win2000 and up, we simply delegate to OLE32’s CoWaitForMultipleHandles service.  And before we wrote the initial cut of our pumping code for NT4 and Win9X, I thought I would glance through CoWaitForMultipleHandles to see how it is done.  It is many, many pages of complex code.  And it uses special flags and APIs that aren’t even available on Win9X.

The code we finally wrote for the downlevel platforms is relatively simple.  We gather the list of hidden OLE windows associated with the current STA thread and try to restrict our pumping to the COM calls which travel through them.  However, a lot of the pumping complexity is in USER32 services like PeekMessage.  Did you know that calling PeekMessage for one window will actually cause SendMessages to be dispatched on other windows belonging to the same thread?  This is another example of how someone made a tradeoff between reentrancy and deadlocks.  In this case, the tradeoff was made in favor of reentrancy by someone inside USER32.

By now you may be thinking “Okay.  Pump more and I get reentrancy.  Pump less and I get deadlocks.”  But of course the world is more complicated than that.  For instance, the Finalizer thread may synchronously call into the main GUI STA thread, perhaps to release a pUnk there, as we have seen.  The causality from the Finalizer thread to the main GUI STA thread is invisible to the CLR (though the CLR Security Lead recently suggested using OLE channel hooks as a technique for making this causality visible).  If the main GUI STA thread now calls GC.WaitForPendingFinalizers in order to pump, there’s a possibility of a deadlock.  That’s because the GUI STA thread must wait for the Finalizer thread to drain its queue.  But the Finalizer thread cannot drain its queue until the GUI thread has serviced its incoming synchronous call from the Finalizer.

**Reentrancy, Avalon, Longhorn and the Client**

Ah, reentrancy again.  From time to time, customers inside or outside the company discover that we are pumping messages during managed blocking on an STA.  This is a legitimate concern, because they know that it’s very hard to write code that’s robust in the face of reentrancy.  In fact, one internal team completely avoids managed blocking, including almost any use of FX, for this reason.

Avalon was very upset, too.  I’m not sure how much detail they have disclosed about their threading model.  And it’s certainly not my place to reveal what they are doing.  Suffice it to say that their model is an explicit rental model that does not presume thread affinity.  If you’ve read this far, I’m sure you approve of their decision.

Avalon must necessarily coexist with STAs, but Avalon doesn’t want to require them.  The CLR and Avalon have a shared long term goal of driving STAs out of the platform.  But, realistically, this will take decades.  Avalon’s shorter term goal is to allow some useful GUI applications to be written without STAs.  Even this is quite difficult.  If you call the clipboard today, you will have an STA.

Avalon also has made a conscious design choice to favor deadlocks over reentrancy.  In my opinion, this is an excellent goal.  Deadlocks are easily debugged.  Reentrancy is almost impossible to debug.  Instead, it results in odd inconsistencies that manifest over time.

In order to achieve their design goals, Avalon requires the ability to control the CLR’s pumping.  And since we’ve had similar requests from other teams inside and outside the company, this is a reasonable feature for us to provide.

V1 of the CLR had a conscious goal of making as much legacy VB and C++ code work as was possible.  When we saw the number of applications that failed to pump, we had no choice but to insert pumping for them – even at the cost of reentrancy.  Avalon is in a completely different position.  All Avalon code is new code.  They are in a great position to define an explicit model for pumping, and then require that all new applications rigorously conform to that model.

Indeed, as much as I dislike STAs, I have a bigger concern about Longhorn and its client focus.  Historically, Microsoft has built a ton of great functionality and added it to the platform.  But that functionality is often mixed up with various client assumptions.  STAs are probably the biggest of those assumptions.  The Shell is an example of this.  It started out as a user-focused set of services, like the namespace.  But it’s growing into something that’s far more generally useful.  To the extent that the Shell wants to take its core concepts and make them part of the base managed Longhorn platform, it needs to shed the client focus.  The same is true of Office.

For instance, I want to write some code that navigates to a particular document through some namespace and then processes it in some manner.  And I want that exact same code to run correctly on the client and on the server.  On the client, my processing of that document should not make the UI unresponsive.  On the server, my processing of that document should not cause problems with scalability or throughput.

Historically, this just hasn’t been the case.  We have an opportunity to correct this problem once, with the major rearchitecture that is Longhorn.  But although Longhorn will have both client and server releases, I worry that we might still have a dangerous emphasis on the client.

This may be one of the biggest risks we face in Longhorn.

**Winding Down**

Finally, I feel a little bad about picking something I don’t like and writing about it.  But there’s a reason that this topic came up.  Last week, a customer in Japan was struggling with using mshtml.dll to crack some HTML files from inside ASP.NET.  It’s the obvious thing to do.  Clearly ‘mshtml’ stands for Microsoft HTML and clearly this is how we expect customers to process files in this format.

Unfortunately, MSHTML was written as client-side functionality.  In fact, I’m told that it drives its own initialization by posting Windows messages back to itself and waiting for them to be pumped.  So if you aren’t pumping an STA, you aren’t going to get very far.

There’s that disturbing historical trend at Microsoft to combine generally useful functionality with a client bias again!

We explained to the customer the risks of using client components on a server, and the pumping behavior that is inherent in managed blocking on an STA.  After we had been through all the grisly details, the customer made the natural observation:  None of this is written down anywhere.

Well, I still never talked about a mysterious new flag to CoWaitForMultipleHandles.  Or how custom implementations of IMessageFilter can cause problems.  Or the difference between Main and Single.  Or the relationship between apartments and COM+ contexts and ServicedComponents.  Or the amazing discovery that OLE32 sometimes requires you to pump the MTA if you have DCOM installed on Win9X.

But I’m sure that at this point I’ve said far more than most people care to hear about this subject.
