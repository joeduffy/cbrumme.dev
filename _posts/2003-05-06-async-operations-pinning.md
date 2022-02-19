---
layout: post
title: Asynchronous operations, pinning
permalink: async-operations-pinning
date: 2003-05-06 21:41:00.000000000 -07:00
status: publish
type: post
published: true
---

One thing we tried to do with the CLR and FX is provide a consistent asynchronous programming model.

To briefly recap the model, an API called XXX may also offer an async alternative composed of BeginXXX and EndXXX methods.  Even if the class that implements XXX doesn’t also offer BeginXXX and EndXXX, you can define a Delegate class whose signature is consistent with the signature of XXX.  On that Delegate, you will find BeginXXX and EndXXX methods defined, which can be used to call the XXX method asynchronously.

The BeginXXX method takes the inbound arguments, an optional state object and an optional callback delegate.  It returns an implementation of IAsyncResult that can be used to rendezvous with the completion.

The managed asynchronous programming model provides a choice of four different ways to rendezvous with the completion:

1. The asynchronous provider calls the delegate callback specified in the BeginXXX call, passing the optional state object. 
2. The initiator polls for completion, using the IAsyncResult.IsComplete property. 
3. The initiator waits for an event to be signaled, via IAsyncResult.WaitHandle. 
4. The initiator blocks until the asynchronous operation completes, by calling the EndXXX API.

Of these four techniques, the first is by far the most popular and arguably the easiest for developers to code to.

The second could be used in a highly scalable server, which can afford a dedicated thread to routinely poll all outstanding asynchronous operations and process any that have completed.

The third technique can be used to process each operation as it completes (WaitHandle.WaitAny) or to process all operations after the last one completes (WaitHandle.WaitAll).  Because WaitHandles are expensive resources, a sophisticated implementation of IAsyncResult may delay materializing the handle until a client requests it.  In most cases, the client will select a different rendezvous method and the WaitHandle is never needed.

The fourth technique is the hardest to understand.  Why initiate an operation asynchronously if you intend to rendezvous with it synchronously?  But this can make sense if the application is interleaving a finite amount of synchronous processing with the asynchronous operation, to reduce latency.  Once the synchronous processing is complete, it may make sense to block.

Regardless of which of these techniques is used to achieve the rendezvous, the final step of the completion is to call the EndXXX API to retrieve the return value, any outbound arguments, or possibly an exception.  If the rendezvous is of the first form, the EndXXX method is probably called directly out of the callback.

Once the EndXXX API returns, the operation is fully complete and the IAsyncResult serves no further purpose.  Since there may be significant resources associated with the operation, the IAsyncResult implementation might treat EndXXX as the equivalent of IDisposable.Dispose().  For instance, any materialized WaitHandle can be disposed at this time.

One of the most common questions related to the managed asynchronous programming model is whether it’s strictly necessary to call EndXXX.  If the operation doesn’t have any return values or outbound arguments, then it’s certainly convenient to “Fire and Forget.”  However, there are a few problems with this:

1. If the operation fails, a call to EndXXX will throw the exception that signals this failure.  If the application never calls EndXXX, it has no way of knowing whether the asynchronous operation actually happened.

2. As we’ve seen, EndXXX is an opportunity for resources to be eagerly disposed.  If you don’t call EndXXX, those resources must be retained until the GC collects the IAsyncResult object and finalizes it.  On the server, this can be a significant performance issue.

3. The last time I checked, some of the FX async APIs would misbehave if EndXXX is not called.  For example, finalization of a stream and finalization of any pending IAsyncResult objects are not well ordered.  Because of the subtlety involved in efficiently fixing these cases, there’s some debate over whether these are framework bugs or application bugs.

4. Skipping the EndXXX calls is sloppy.  This is certainly a matter of taste, but I consider it a strong argument.

Because of the above reasons, you should always balance a successful BeginXXX call with its EndXXX counterpart.

Another common question has to do with the best way to perform a synchronous operation asynchronously.  If an API offers BeginXXX / EndXXX methods, you should use them.  This is definitely going to be the technique with the best performance.  But if you only have an XXX API, you still have several obvious choices:

1. Create a new Thread which calls XXX and then dies.

2. ThreadPool.QueueUserWorkItem() allows a client to call XXX on a ThreadPool thread.  The rendezvous model is similar to the delegate callback mechanism we already discussed.

3. Create a Delegate over XXX and then call the BeginXXX / EndXXX methods on that delegate.

The first choice is almost never the correct one.  You should only create a dedicated thread if you have a long-running use for one, or if your thread must be different from all the “anonymous” threads in the threadpool.  (For example, threadpool threads are all CoInitialized for the MTA.  If you need an STA thread, you need to create your own thread).

The second choice will actually perform better than using a Delegate’s BeginXXX / EndXXX methods.  If you are queueing work in your own AppDomain, this is the way to go.  I know that with work we can narrow the performance gap between QueueUserWorkItem and asynchronous Delegates, but I don’t think we can ever achieve parity.

If your application is making asynchronous calls on remote objects, then asynchronous Delegates have an important optimization.  They don’t actually switch to a different thread in this case.  Instead, they synchronously initiate a remote call from the calling thread and then return.  Asynchronous Delegates have the additional benefit of sharing a consistent model with explicit BeginXXX / EndXXX APIs in FX, so you may prefer them to QueueUserWorkItem for this reason.

Finally, a word on pinning.  I often see applications that aggressively pin managed objects or managed delegates that have been passed to unmanaged code.  In many cases, the explicit pin is unnecessary.  It arises because the developer has confused the requirement of tracking an object instance via a handle with the requirement of keeping the bytes of that object at a fixed location in memory.

For normal PInvokes, a blittable type exposes the bytes of an object in the GC heap directly to unmanaged code.  This obviously means that the bytes mustn’t be moved by a GC relocation until the unmanaged code has stopped accessing them.  In most cases, the PInvoke layer can automatically pin the bytes for the lifetime of the call.  And this layer can pin those bytes in a more efficient manner than you could with a pinned GCHandle.  (The PInvoke layer is hooked into the CLR’s stack crawling mechanism for GC reporting.  So it can defer all overhead related to pinning unless a GC actually occurs while the PInvoke call is in progress).  Applications that explicitly pin buffers around PInvoke calls are often doing so unnecessarily.

Along the same lines, managed Delegates can be marshaled to unmanaged code, where they are exposed as unmanaged function pointers.  Calls on those pointers will perform an unmanaged to managed transition; a change in calling convention; entry into the correct AppDomain; and any necessary argument marshaling.  Clearly the unmanaged function pointer must refer to a fixed address.  It would be a disaster if the GC were relocating that!  This leads many applications to create a pinning handle for the delegate.  This is completely unnecessary.  The unmanaged function pointer actually refers to a native code stub that we dynamically generate to perform the transition & marshaling.  This stub exists in fixed memory outside of the GC heap.

However, the application is responsible for somehow extending the lifetime of the delegate until no more calls will occur from unmanaged code.  The lifetime of the native code stub is directly related to the lifetime of the delegate.  Once the delegate is collected, subsequent calls via the unmanaged function pointer will crash or otherwise corrupt the process.  In our recent release, we added a Customer Debug Probe which allows you to cleanly detect this – all too common – bug in your code.  If you haven’t started using Customer Debug Probes during development, please take a look!

So there are lots of places where applications often pin unnecessarily.  The reason I bring this up is that asynchronous operations through unmanaged code are an important and legitimate scenario for pinning.  If you are passing a buffer or OverlappedStruct out to an asynchronous unmanaged API via a PInvoke, you had better be pinning that object.  We have a Customer Debug Probe that attempts to validate your pinning through some stressful GC and Finalization calls around the PInvoke call.  But this sort of race condition is necessarily a hard bug to provoke cleanly, and the performance impact of this probe is significant.

Whenever you pin an object like a buffer, you should consider whether the buffer is naturally long-lived.  If it is not, consider whether you could build a buffer recycling cache so that the buffers become long-lived.  This is worth doing because the cost of a pin in the oldest generation of the GC heap is far less than the cost of a pin in the youngest generation.  Objects that have survived into the oldest generation are rarely considered for collection and they are very rarely compacted.  Therefore pinning an old object is often a NOP in terms of its performance impact.

Of course, if you are calling explicit BeginXXX / EndXXX APIs in FX (like Stream.BeginRead / EndRead), then the pinning isn’t your concern.  The Stream implementation is responsible for ensuring that buffers are fixed if it defers to unmanaged operations that expect fixed memory locations.

Along the same lines, if you call explicit BeginXXX / EndXXX APIs, AppDomain unloads need not concern you.  But if you call asynchronous unmanaged services directly via PInvoke, you had better be sure that an AppDomain.Unload doesn’t happen while you have a request in flight.  If it does, the pinning handles will be reclaimed as part of the unload.  This might mean that the asynchronous operation scribbles into the GC heap where a buffer or OverlappedStruct used to be.  The resulting heap corruption puts the entire process at risk.

There’s no good story for this in the current product.  Somehow you must delay the unload until all your asynchronous operations have drained.  One way to do this might be to block in the AppDomain.UnloadDomain event until the count of outstanding operations returns to 0.  We’ll be making it easier for you to remain bullet-proof in this sort of scenario in future versions.

So if you can find specific FX asynchronous APIs to call, all this nastiness is handled for you.  If instead you define your own managed asynchronous APIs over some existing unmanaged implementation, you need to be very careful.
