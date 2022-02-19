---
layout: post
title: ReleaseComObject
permalink: releasecomobject
date: 2003-04-16 12:51:00.000000000 -07:00
status: publish
type: post
published: true
---

Developers who are accustomed to the IDisposable pattern or to C#’s ‘using’ syntax sometimes ask why COM Interop doesn’t support IDisposable on every Runtime Callable Wrapper (RCW).  That way, managed code could indicate that it is finished using the unmanaged COM resource.  This would allow the resources to be cleaned up much earlier than they would be if we waited for a GC.  Also, it might better approximate the way an unmanaged client would have used this COM object through explicit Release calls.

There’s a service called System.Runtime.InteropServices.Marshal.ReleaseComObject() that looks suspiciously like it could be used as a Dispose() call.  However, this is misleading.  ReleaseComObject is quite different from Dispose() and it’s also quite different from IUnknown::Release() as I’ll explain.

The COM Interop layer in the CLR can make do with a single reference count against the unmanaged pUnk, regardless of how many managed clients refer to that object.  In other words, the Interop layer does not hold a reference count for each managed client of that pUnk.  Instead, we rely on the reachability magic of the GC to determine when nobody needs that pUnk anymore.  When nobody needs the pUnk, then we drop our single reference count on that pUnk.

Furthermore, negotiation for interfaces in managed code via COM Interop does not necessarily affect the unmanaged refcount of the COM object.  For instance, the managed wrapper might have already cached a pUnk for this interface.

Regardless of the actual refcount that the wrapper holds on the underlying COM object, ReleaseComObject will release all these refcounts at one time.

However, the return value from ReleaseComObject reveals that there’s an additional refcounting scheme involved.  This is unrelated to the COM refcount.  The same pUnk might be marshaled into the managed process a number of times.  We keep track of this count.  You can then call ReleaseComObject that same number of times before we will call IUnknown::Release on the pUnks held by the wrapper and start giving throwing InvalidComObjectExceptions.  If you are passing the pUnk backwards and forwards across the layer, this means that the “marshaling count” will be a large and arbitrary number.  But, for some usage patterns, the number of times the pUnk is marshaled across may correspond to the number of distinct managed clients that have got their hands on the wrapper.  If this happens to be the case, then that many managed clients can independently call ReleaseComObject before the wrapper is zombied and the underlying pUnks are Release’d.

I guess that this behavior is slightly more useful than a simple Release in some circumstances.  And you can turn it into the equivalent of IUnknown::Release by calling it in a loop until it returns 0.  At that point, our internal “marshaling count” has been decremented to 0 and we have Release’d the pUnks.  (We really need to add a ReleaseComObjectFully() service to avoid that silly loop).

Application code can either be on the GC plan, where we track whether there are references outstanding – but in a non-deterministic manner that is guided by memory pressure – or application code can do the tracking itself.  But if the application does the tracking, it is responsible for knowing whether there are other managed clients still using the COM object.

One way you might do this is by subtyping the wrapper and adding a Dispose protocol on the managed side that is reference counted.  But all managed clients in the process must observe the discipline you define.  A more practical approach is to ensure that you are the only client of the pUnk by creating the COM object yourself and then never sharing that reference with anyone else.

If you are using a COM object in a scoped, single-threaded manner then you can safely call ReleaseComObject on that object when you are done with it.  This will eagerly release any unmanaged resources associated with that object.  Subsequent calls would get an InvalidComObjectException.  So don’t make subsequent calls.

But if you are using a COM object from multiple places or multiple threads in your application (or from other applications in the same process), you should not call ReleaseComObject.  That’s because you will inflict InvalidComObjectExceptions on those other parts of the application.

So my advice is:

1. If you are a server application, calling ReleaseComObject may be an important and necessary requirement for getting good throughput.  This is especially true if the COM objects live in a Single Threaded Apartment (STA).  For example, ASP compatibility mode uses the DCOM STA threadpool.  In these scenarios, you would create a COM object, use it, then eagerly call ReleaseComObject on each request.

2. If you are a client application using a modest number of COM objects that are passed around freely in your managed code, you should not use ReleaseComObject.  You would likely inflict Disconnected errors on parts of the application by doing so.  The performance benefit of eagerly cleaning up the resources isn’t worth the problems you are causing.

3. If you have a case where you are creating COM objects at a high rate, passing them around freely, choking the Finalizer thread, and consuming a lot of unmanaged resources… you are out of luck.
