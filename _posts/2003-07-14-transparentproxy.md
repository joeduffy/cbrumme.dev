---
layout: post
title: TransparentProxy
permalink: transparentproxy
date: 2003-07-14 15:58:00.000000000 -07:00
status: publish
type: post
published: true
---

One of the recurring requests for a blog is related to TransparentProxy, RealProxy, Contexts, Interception, etc.  As usual, I’m typing this where I don’t have access to our corporate network and the sources, so some details might be a little off.  (When will my dentist provide free wireless to his customers?)  And, as usual, none of this is going to help you in developing applications.  In fact, I postponed writing about this topic – despite all the requests – because it seems so obscure.  But if you are struggling through the Rotor source base, it might explain some of the code that you see.  I say ‘might’ because I’ve never actually looked at the Rotor sources.  I’m just relying on the fact that they are a pretty faithful of a cleansed snapshot of our desktop CLR sources.  Anyway…

Normally, a reference to a managed object is just that: a native memory pointer.  This is reported accurately to the GC so that we can track reachability and so we can update that pointer if the object is relocated during a compaction.  But in the case of an object that derives from MarshalByRefObject (MBRO), it’s possible that the object instance is actually remote.  If this is the case, a proxy stands in for the server instance.

**The TP / RP Pair**

In fact, we don’t have a single proxy for this case.  Instead, we have a proxy pair.  This pair consists of a System.Runtime.Remoting.Proxies.__TransparentProxy (TP) and a RealProxy (RP).  The client calls on the TP; the TP forwards the calls to the RP; the RP usually delivers calls to a remote server object via a channel.  I say ‘usually’ because the RP can actually do whatever it wants.  There doesn’t even have to be a remote server object if you have a clever enough RP.

Why would we have both a TP and an RP?  Clearly there’s a performance penalty associated with using two proxies.  We have to instantiate them both and we force calls to take a doubly-indirected path.  This overhead is necessary because the TP and RP are for different reasons:

The TP is pure magic.  Its job is to fool all the CLR code that performs casting, field access, method dispatch, etc. into thinking that it’s dealing with a local instance of the appropriate type.  In contrast, the RP has absolutely no magic.  Its job is to provide an extensibility point where we can define RemotingProxy, or YourOwnProtocolProxy.  It simply isn’t possible for us to combine magic with extensibility on the same object, as we shall see.

So how does the TP work its magic?  Throughout the code base, whenever we are making type-based decisions (like GetType(), castclass & isinst IL opcodes), we’re careful to consider the TP type’s special ability to stand in for other types.  In our method dispatch pathways, we are always careful to tease out the cases where a TP might lie in the callpath and deliver the calls to that object rather than optimizing the dispatch.  Whenever we are accessing fields, creating byrefs, or otherwise referring to instance state, we ensure that these operations are delivered to the TP in a virtualized way.

Let’s look at these operations in more detail.  In the discussion that follows, we are only interested in operations on potentially remote instances.  Potentially remote instances include:

* The MBRO type and all types that derive from it, including ContextBoundObject (CBO) and __ComObject.
* Interface methods, since these interfaces could be implemented on a MBRO type.
* All methods of Object since, by widening, a remote MBRO instance could be passed around formally as Object.

Significantly, types in the hierarchy below Object and disjoint from MBRO can never be remoted.  In this portion of the hierarchy, which contains the vast majority of all types and includes all array types, we are free to inline methods, perform direct field access, perform calls without indirecting stubs, take byrefs, etc., without any consideration for remoting overheads.  As I explained in a prior blog, this is why we don’t allow you to use a marker interface to indicate remotability – it must be boiled into the singly-inherited hierarchy.  Otherwise, widening would prevent us from applying optimizations like direct field access to anything but sealed classes.

**Statics**

In an earlier blog, I already explained why we never remote static members.  Static members don’t involve a ‘this’, so they completely bypass the proxy and proceed like local calls.

**Virtuals**

When the CLR is using VTables for virtual dispatch, all it needs to do is construct a VTable for the TP class that is at least as long as the longest VTable loaded by any type in the process.  We do this by reserving enough virtual memory for the longest legal VTable, and then we commit and prepare pages of this VTable as required by dynamic class loads of other proxyable types.  Slot ‘n’ of this VTable does something like “PUSH n; JMP CommonStub”.  In other words, the purpose of this VTable is to capture which slot was called through and then perform some common processing on it.  I’ll explain the common processing later.

I’ve also implied that the CLR might not use VTables for virtual dispatch.  Hopefully it’s obvious that most of what I discuss is specific to a particular implementation of the CLR.  Almost all of these details can change from release to release.  And I would expect them to be very different in other implementations of the CLI.  Whether the CLR continues to use VTables in a future release is a different rat-hole.

Anyway, the great thing about the virtual case is that the test for whether something is local or remote is completely hidden in the normal indirection of a virtual dispatch.  There are no additional penalties.

**Non-virtuals**

Bashing VTables is a fairly standard technique.  But non-virtual methods aren’t generally called through indirections.  There are some exceptions to this rule, like NGEN cross-assembly calls and JITted calls to methods that haven’t yet themselves been JITted.  However, in the typical case, we make non-virtual calls direct to the target method, just like static calls.  Even when C# emits a ‘callvirt’ IL opcode to target a non-virtual method, this just forces us to check that the ‘this’ is non-null, as we’ve seen in an earlier blog (e.g. ‘mov eax, [ecx]’).  If we are dispatching on a TP instead of a local instance, this non-null check isn’t going to help us capture the call.

Instead, for every non-virtual call on a potentially remote instance, we go through a special stub.  This stub is constructed on-demand for a specific remoted method body and is then cached in case we find other callsites that need it.  The purpose of the stub is to quickly check whether the server object is local to the calling thread.  The details of this test depend on exactly what might be proxied.  In the case of a normal MBRO, we’re just interested in whether the client’s reference is to a TP or to a local instance.  In the case of a CBO, the client’s reference is always to a TP.  So in that case we are interested in whether the thread is already in the server’s context or whether a context transition must be performed.  More on this later, too.

**Virtuals called non-virtually**

In an earlier blog, we saw how it’s possible to call virtuals in a non-virtual fashion.  This supports C#’s ‘base’ calls and the more flexible scope override operator ‘::’ of Managed C++.  Of course, these cases are relatively rare.  Virtual methods are almost always called virtually.  Anyway, we handle non-virtual calls to potentially remote virtual methods by lazily creating and caching stubs as in the non-virtual method case.

**Interfaces**

You might think that interfaces would be handled just like virtual calls, since we place the interface methods into each type’s VTable during class layout.  However, the necessities of efficient interface dispatch cause some additional problems.  Let’s side-track on how interfaces work, for a moment.

The same interface can be implemented on multiple different classes.  Each class will contain the methods for the interface contract at possibly different places in its VTable.  The callsite is polymorphic with respect to the class of the server.  So our goal is for the dispatch to discover, as quickly as possible, where the appropriate interface methods can be discovered on the receiver’s class.  (There are other ways of performing interface dispatch that finesse this goal, like using fat pointers or interface proxy instances.  Those other techniques have their own problems.  And this is a blog on TP / RP, not interfaces, so let’s stick with the goal that I’ve stated).

We’re currently on our 4th implementation of interface dispatch.  The implementation that’s in the Rotor sources and was shipped in V1 and V1.1 was our 3rd implementation.  In that design, every interface is assigned a unique interface number during loading.  Each class that implements one or more interfaces has a secondary interface table or ITable which is available via an indirection from the standard VTable.  Dispatch occurs by indirecting through this ITable using the interface number of the interface.  This points us back to a section of normal VTable (usually within the receiver’s normal class VTable somewhere) where the interface’s methods are laid out.  Of course, the ITable is incredibly sparse.  A given class might implement just the interfaces numbered 1003 and 2043.  We only need two slots for that class, so it would be extremely wasteful to burn 2044 slots.  Therefore a key aspect of this design is that the ITables are all allocated sparsely in a single shared heap.  It’s important to find an algorithm that can efficiently pack all the ITables for all the classes we have loaded, without forcing our class loader to solve a “knapsack” problem.

The above works well for normal types, which each implement a bounded set of interfaces.  But the TP class needs to implement all interfaces because it must stand in for all possible classes.  In a similar way, the __ComObject class must implement all interfaces on all RCWs.  That’s because a QueryInterface on some instance of a particular RCW type might one day say “Yes, I implement that interface.”  (By the end of this blog you will know why __ComObject isn’t just a TP with a specialized RP implementation that understands COM rules).

Here’s what a virtual dispatch might look like on X86, with a shipping version of the CLR.

```
mov  eax, [ecx]         ; get the VTable from ‘this’
call [eax+mslot*4]      ; call through some slot
```

And here’s an equivalent interface dispatch, which shows the indirection through the ITable.

```
mov  eax, [ecx]         ; get the VTable from ‘this’
mov  eax, [eax+j]       ; get the ITable at some offset from it
mov  eax, [eax+islot*4] ; get the right interface VTable
call [eax+mslot*4]      ; call through some slot
```

Leaving aside all the cache faults that might cripple us, the interface dispatch looks pretty good.  It’s just a couple more instructions than the virtual dispatch.  And we certainly don’t want to slow down this great interface dispatch for our typical case, in order to support the unbounded nature of TP and __ComObject interface dispatch.  So we need a data structure for TP that will work for all potentially remote types and all the interfaces.  The solution is to have a single ITable for these cases, which is fully populated with all the interfaces we have ever loaded.  Obviously we have to grow this by committing more memory as the application faults in more interfaces.  And each entry in the ITable points to a bit of VTable representing the appropriate interface, where the slots are full of stubs.  The stubs contain machine code that says something like “If my ‘this’ is a TP, go do the remoting stuff.  Otherwise my ‘this’ better be a __ComObject of some kind and I must go do the COM Interop stuff.”  We actually use the VTables of the interface types themselves (which otherwise would contain nothing interesting in their slots) for this purpose.

If you are struggling to understand interface dispatch in the Rotor sources, the above might provide some useful guidance.  The bad news is that we have switched to a somewhat different technique in our current codebase.  Of course, I can’t predict when this new technique will ship in a CLR product or when it might show up in a new Rotor drop.

**Constructors**

Constructors are like non-virtual calls, except for the twist that – when they are mentioned in a ‘newinst’ IL opcode rather than a ‘call’ or ‘callvirt’ IL opcode – they involve an object allocation.  In remoting scenarios, it’s clearly important to combine the remote allocation with the remote execution of the instance constructor method to avoid a 2nd round-trip.

**Instance Field Access and Byrefs**

If a type cannot be remoted, all field access is direct.  The X86 JIT tends to produce tight code like ‘mov eax, [ecx+34]’ if it is loading up a field.  But this clearly won’t work if a TP is involved.  Instead, the field access is turned into an implicit property access that can be remoted.  That’s great for the case where the server truly is remote.  But it’s an unfortunate penalty for the case where the server is local and was only potentially remote.

In the case of a byref, once again the JIT is normally efficient (e.g. ‘lea eax, [ecx+34]’).  You might imagine that we could virtualize the byref the way we virtualize the implicit property access.  In other words, we could generate a secret local and prime it with the value of the field (umm, property).  Then we could make the call with a byref to the local as the argument.  When the call returns, we could back-propagate the – perhaps updated – value of the local back into the field/property.  The machinery to do this is relatively straight-forward.  But it breaks the aliasing assumptions of byrefs.  For example, if you were to update the field through the byref and then examine the server before unwinding the stack, the byref modification would not have been propagated back to the server object yet.

For better or for worse, the current implementation doesn’t go this route.  Instead, the CLR allows you to take a byref to a field of a potentially remote object if that object is in fact local.  And it throws an exception if you attempt to take such a byref on a potentially remote object that is indeed remote.

In passing, I should mention that some languages, like C#, won’t allow you to even attempt to take a byref on a potentially remote object (subjecting yourself to exceptions if the server is indeed remote).  Instead, they force the developer to explicitly create the local, pass a byref to that local, and perform the back-propagation.  This way there’s no magic and the developer understands exactly when and how his values get updated.

And I should also point out that if you call a method on a remote MBRO server, passing a byref to a field of a non-MBRO local object or to a static field or to a local, that same aliasing issue can be observed.  In that case, we decided it was okay to allow observable aliasing discrepancies until the stack unwinds and the byref back-propagation can occur.

**Casting, progressive type refinement**

So far, I’ve been a little sloppy with the term VTable.  Managed objects actually have a MethodTable.  The MethodTable is currently implemented to have some GC info growing at a negative offset from the MethodTable (to tell the GC where all the pointers are for tracing), some “hot” metadata, and then a VTable.  Part of the “hot” metadata is a parent pointer so we can traverse up the single-inheritance hierarchy and a list of implemented interfaces so we can perform interface casting.

So normally all our type tests are based on the MethodTable of the instance.  But the TP has a rather uninteresting parent pointer (System.Object) and an empty list of implemented interfaces.  This means that all of the type checks tend to fail.  In the failure path, right before we throw an exception, we say “Oh, is this one of those weird cases like TP or __ComObject?”  If it is, we vector off to an appropriate routine that understands how to perform QueryInterface calls or ManagedRemoting calls or whatever is appropriate for each case.  Unless the Rotor source cleansing process performed a rename, there’s probably a routine in JITInterface.cpp called JITutil_CheckCastBizarre that’s an example of how we handle these weird cases.  Note that they are typically placed into the failure paths, so the requirements of remoting don’t impact the performance of the local cases.

For the cases where we have a CBO, we can trivially know the exact type of the server instance.  Everything is loaded in the same process and we can encode the server’s type with a MethodTable in the normal fashion.  But if the client and server are in different AppDomains, processes, or machines then type injection becomes a consideration.  In an earlier blog, I’ve talked about the security threats that depend on injecting an assembly into someone else’s AppDomain.  For example, it may be possible for an assembly to escape the restrictive security policy of one AppDomain by injecting itself into the host’s AppDomain.  Furthermore, inadvertent type injection across an AppDomain boundary can interfere with a host’s ability to discard types through AppDomain unloading.  That’s why we return an ObjectHandle from the various AppDomain.CreateInstance and CreateInstanceFrom overloads.  You must explicitly unwrap the ObjectHandle or use a CreateInstanceAndUnwrap convenience helper, to opt-in to the injecting behavior.

Another mechanism that helps you control type injection is ‘progressive type refinement’.  This mechanism leverages the ability of a TP to stand-in for all different types.  When you marshal back a remote MBRO, a TP is created in the client’s Context and AppDomain.  (The Context is typically the default Context for the AppDomain, unless you are using CBOs).  Consider the following code fragments:

```
AppDomain ad = …;
Object o = ad.CreateInstanceAndUnwrap(…);
SomeIface i = (SomeIface) ad.CreateInstanceAndUnwrap(…);
SomeClass c = (SomeClass) ad.CreateInstanceAndUnwrap(…);

Type t = c.GetType();
```

So long as the object we create in the remote AppDomain ‘is-a’ MBRO, the result of executing CreateInstanceAndUnwrap() will be a TP that masquerades as an instance of type System.Object.  If we then cast the unwrapped object to SomeIface, our program obviously has mentioned that type in an early-bound manner in the client’s AppDomain.  So that type is already present and doesn’t need to be injected.  If the remote object can indeed be cast to SomeIface, the TP will refine its notion of the remote server’s type so that it includes SomeIface.  In a similar fashion, the TP can be refined to understand that it is-a SomeClass – and all the super-classes and implemented interfaces of SomeClass.

Unfortunately, calls like c.GetType() terminate our ability to limit the type knowledge in the client’s Context / AppDomain.  If you actually ask for the fully derived type of the remote concrete instance, we must obtain that remote type and attempt an injection of it into the client’s Context.  However, for constrained patterns of calls, it’s possible for the host to get some real benefits from this feature.

Clearly we can only support progressive type refinement on objects that marshal by reference with a TP.  Objects that marshal by value will necessarily inject the full type of the concrete instance that is produced during the unmarshal.

So we’ve seen how TP intrudes in the normal processing of calls, field access, and type checking.

Now we can understand the reasons why the TP and RP must be separated.  Any call on the TP is captured into a message object and forwarded to the RP.  The RP author (either our Managed Remoting team or you as a 3rd party extension) now wants to operate on that message.  Any methods and fields you define for this purpose must necessarily be on a different type than the TP.  If they were defined on the TP, they would be subject to the same capture into a message.  We would never get any work done until the consequent infinite recursion blows the stack.

There’s a small lie in the above.  We actually have a few methods that are exempt from this automatic “capture and forward.”  Object.GetHashCode(), when it isn’t overridden by the remotable subtype, is an example.  But if we wanted to allow you to add arbitrary methods, fields and interfaces to your RP implementation, we would have an impossible mess of ambiguities.  Slot 23 in the TP’s VTable would somehow be a captured call for every remotable type in the system and a necessary local execution of some RP behavior on that captured call.

Along the same lines, any call to GetType() or use of the castclass and isinst IL opcodes would be ambiguous if we merged the TP and RP.  We wouldn’t know if we should deliver the TP semantics of pretending to be the remote server’s type, or whether we should deliver the RP semantics of your extensibility object.

**The Common Stub**

Let’s go back to the stubs in the VTable of the TP, which capture virtual calls.  I already said that they look like “PUSH ‘n’; JMP CommonStub”.  The common stub has to somehow convert the small integer in EAX into something more useful – the MethodDesc of the target method.  (A MethodDesc is an abbreviation for method descriptor.  It’s the piece of internal metadata that uniquely describes each method, including its metadata token, how to generate code for it, where the generated code can be found, the signature of the method, the MethodTable that contains it, and any special information like PInvoke marshaling or COM Interop information.  We encode this pretty tightly and it usually fits into 32 bytes).

All virtual methods are instance methods, so we can use the ‘this’ of the call to help us obtain the desired MethodDesc.  In the case of X86, we currently pass ‘this’ in ECX.  So all we need to do is find the ‘n’th virtual method in the VTable of the type of the instance in ECX.

Something similar can happen in the interface dispatch case.  Recall that we end up in a stub that hangs off the interface type’s VTable rather than the receiving class’ VTable.  So this stub can trivially deliver up the relevant MethodDesc.

And for the non-virtual methods (and virtual methods called non-virtually), it’s even easier.  In each case, we create a stub that is specific to that method.  So this stub can contain the MethodDesc as an immediate argument burned into its code.

This means that all the method dispatch scenarios can obtain a MethodDesc and then jump to a common location.  That common location now has enough information to capture all the arguments into a System.Runtime.Remoting.Messaging.Message which can disassociate itself from the stack for asynchronous or cross-process remoting.  Or it can just use that information to efficiently access the registers and stack locations containing the arguments of the call, for the case where the interception remains inside the same process.

Unfortunately, we don’t take advantage of that 2nd faster option as much as we should in V1 and V1.1.  We have plenty of evidence that calls on TPs could be significantly faster in cross-Context and cross-AppDomain scenarios if we teased them apart from the more general remoting codepaths.  By “significantly faster”, I mean at least one order of magnitude for some common and important cases.  It’s likely that you’ll see at least some improvement here in our next release.  And it’s also likely that even in our next release we will have ignored significant performance opportunities.

One surprising fact is that this is also why Delegate.BeginInvoke / EndInvoke are so slow compared to equivalent techniques like ThreadPool.QueueUserWorkItem (or UnsafeQueueUserWorkItem if you understand the security implications and want to be really efficient).  The codepath for BeginInvoke / EndInvoke quickly turns into the common Message processing code of the general remoting pathway.  That’s fine if you are making asynchronous calls on remote objects via a delegate.  In that case, we can avoid the extra context switch that would occur if we didn’t coordinate the remoting code with the async code.  We are careful to initiate the remote operation synchronously on the caller’s thread if that’s the case.  But it means that the local case is dramatically slower than it needs to be.  Of course, when it comes to performance we have much more glaring and general purpose issues to address before this one bubbles to the top of our list.

Finally, when we convert fields to implicit properties for the purposes of remoting, there is no corresponding MethodDesc.  The method doesn’t exist anywhere in metadata.  Instead, we go through a different pathway and use the FieldDesc as the piece of metadata to guide us.

**The Hierarchy**

Here’s the bit of the inheritance hierarchy which pertains to this blog:

```
            Object     Interfaces
              |
              |
      MarshalByRefObject
        /           \
       /             \
 __ComObject     ContextBoundObject
                         |
                         |
                  ServicedComponent
```

As we’ve seen, Object and all Interfaces are potentially remote.  We have to disable some optimizations to account for this.  But anything which derives from Object and which does not derive from MBRO can have all optimizations enabled.  Remoting cannot be a consideration for that portion of the hierarchy.

For MBRO and for classes that derive from MBRO but do not derive from CBO, we have an opportunity to add back an optimization.  If we are operating on ‘this’ in a method of such a type, then we know that the instance is now local.  The reasoning is that if the instance were indeed remote, then the TP should have forwarded the call elsewhere.  Since that didn’t happen, we can add back all the local optimizations like direct field access.

Under CBO, the situation is a little worse.  For various reasons that are all internal implementation details, we currently don’t unwrap CBO.  Even when a thread is executing inside the correct Context and the instance is in that sense local, we leave it as the remote case.

Incidentally, we actually implemented CBO the other way first, where each call into a CBO would rigorously marshal the arguments via wrapping / unwrapping between server instances and TPs.  But this caused terrible performance problems when performing identity comparisons of instances typed as some Interface or as System.Object.  Simple operations like the fetch of a System.Object out of an Object[] required marshaling checks for the correct Context.  We were penalizing typical programming operations for non-Context programming, in order to get a performance benefit if Contexts were indeed used.  This was a poor trade-off and we adopted the current plan.  Of course, leaving aside observable performance differences, either technique delivers the same semantics.

In my opinion, the primary benefit of the CLR is that the semantics of your program have been largely divorced from the details of execution.  We could change practically everything I’ve described in this blog, without affecting your program’s behavior.

Anyway, we currently have one trick up our sleeve for adding back performance to CBO.  If the JIT notices that you are performing a lot of field access on ‘this’, it creates an unwrapped temporary alias for ‘this’.  Then it performs direct field access against the alias, rather than going through the remoting abstraction that converts the field accesses into property accesses.  Clearly we could pursue some other optimizations here, too.

So does this explain why cross-AppDomain and cross-Context calls are so slow?  We know that we have to create additional instances for proxying (the TP and RP).  We know that the callpaths contain various indirections in the form of stubs.  And we know that field access and method inlining and other standard optimizations are sometimes disabled because the server object is potentially remote.

With our current design, all these overheads seem unavoidable.  But the real reason that cross-AppDomain and cross-Context operations are so slow is not due to these unavoidable overheads.  It’s really that we simply haven’t invested enough engineering effort to make them faster.  We could retain our existing design and do a much better job of separating the “same address space” cases from the “different address space” cases.  As I’ve said, I think you’ll see some of these improvements in our next release.  But we will still have a long way to go.

**__ComObject and ServicedComponent**

__ComObject derives from MBRO.  It captures calls, intrudes on type negotiations, involves remoted instantiation, etc.  It must be using TP and RP for all this magic, right?  Actually, no.

I hinted at this when I described the stub that performs interface dispatch on TPs and __ComObjects.  The stub we build on the first call to a particular interface method checks whether the server is a TP or whether it is a __ComObject and then it bifurcates all processing based on this.

If you look at the JITutil_CheckCastBizarre() routine I mentioned earlier, you see something similar.  The code checks to see if it has a TP and it checks for __ComObject separately, with bifurcated processing for the two cases.

This is all historical.  We built COM Interop before we realized we needed to invest in a strong managed remoting story that was distinct from DCOM.  If we were to build the two services again today, we would definitely merge the two.  The TP/RP remoting code is the correct abstraction for building services like COM Interop.  And, indeed, if we had taken that approach then we would have been forced to address some of the “same address space” performance problems with managed remoting as a consequence of achieving our COM Interop performance goals.

This historical artifact is still more evident when you look at ServicedComponent.  In some sense, ServicedComponent is a COM Interop thing.  It’s a managed object that is aware of COM+ 1.0 unmanaged contexts (which are implemented in OLE32.dll on Win2000 and later OS’es).  As such, it delegates creation of these managed objects through CoCreateInstance.  Whenever we call on a ServicedComponent instance, we check whether we are in the correct COM+ 1.0 context.  If we are not, we call through a COM+ service to transition into the correct context which then calls us back.

Yet ServicedComponent is built on top of all the TP / RP infrastructure, rather than on top of __ComObject.  The reason for this is simply that we added EnterpriseServices and ServicedComponent very late in our V1 cycle.  At that point, both the __ComObject pathway and the TP / RP pathway were available to us.  The TP / RP pathway is simply a much cleaner and more general-purpose abstraction for this sort of thing.

If we ever go back and re-implement COM Interop, there are several important things we would change.

First, we would put COM Interop onto the TP / RP plan.

Second, we would rewrite a lot of the COM Interop code in managed.  This is a long term goal for much of the CLR.  Frankly, it’s very hard to write code in the CLR without abusing the exception model, or forgetting to report GC references, or inadvertently performing type-unsafe operations.  All these mistakes lead to robustness and even security bugs.  If we could write more of the CLR in managed code, our productivity would go up and our bug counts would go down.

Third, we would replace all our COM Interop stubs with IL.  Currently, the marshaling of COM Interop calls is expressed in a language called ML (marshaling language).  This was defined at a time when our IL was still in flux, and when we thought we would have a system of JIT-expanded macros that could map ML to a lower-level IL.  We ended up implementing the macro aspect of IL and then dropping it in order to ship V1 sooner.  This left us with the choice of either interpreting ML or writing converters to dynamically generate machine code from simple ML streams.  We ended up doing both.  Now that IL is stable, and now that we are targeting multiple CPU architectures in future versions of the CLR (like IA64), the fact that COM Interop depends on ML is quite a nuisance.

However, it’s not clear whether a re-implementation of COM Interop will ever be a sensible use of our time.

**CBO and Interception**

The COM+ 1.0 approach to call interception is very popular with MTS & COM+ programmers.  Depending on your opinion of that product, this is either because they built a powerful abstraction for interception and Aspect Oriented Programming (AOP), or because when all you have is a hammer then everything looks like a nail.

Personally I think they did a great job of extending the COM model to include a powerful form of interception and AOP.  But it’s tied up with COM-isms, like the fact that side effects such as transaction commit or object pooling occur when the last Release() call happens.  Another COM-ism is that the COM’s rules for apartment marshaling have been extended to apply to finer-grained contexts.  Some aspects of the COM+ model don’t apply well to managed code (like attaching side effects to a Release() call that might be delayed until a GC occurs).  Other aspects could potentially be done better in managed code, since we have the advantage of a strong notion of class and metadata, the ability to generate code on the fly, and the ability to prevent leakage across marshaling boundaries rather than relying on developer hygiene.

During V1 of the CLR, we tried to take the great aspects of the COM+ model and adjust them so they would be more appropriate to the managed world.  The result is ContextBoundObject, System.Runtime.Remoting.Contexts.Context, and all the related classes and infrastructure.

Very briefly, all CBO instances live in Contexts.  All other managed instances are agile with respect to Contexts.  Calls on these agile instances will never trigger a Context transition.  Instead, such instances execute methods in the Context of their caller.  When a Context transition does occur, there is sufficient extensibility for the application or other managed code to participate in the transition.  That code can inject execution into the act of calling out of the caller’s Context, entering into the server’s Context, leaving the server’s Context when the method body completes, and returning to the caller’s Context.  In addition, there is a declarative mechanism for attaching attributes to types of CBO, indicating what sort of Context they should live in.  It is these attributes which are notified as Context transitions occur.  The best example of code which uses this mechanism is the SynchronizationAttribute class.  By attaching this attribute to a class that derives from CBO, you are declaring that any instance of your CBO should participate in a form of rental threading.  Only one thread at a time can be active inside your object.  Based on whether your attribute is Reentrant or not, you can either select a Single Threaded Apartment-style reentrancy (without the thread affinity of an STA, of course) or you can select a COM+ style recursive activity-threaded model.  Another important aspect of Context-based programming is that the activation or instantiation of objects can be influenced through the same sort of declarative interception.

With this rich model, we expected CBO and managed Contexts to be a key extensibility point for the managed programming model.  For example, we expected to reimplement ServicedComponent so that it would depend on managed contexts, rather than depending on unmanaged COM+ contexts for its features.  In fact, our biggest fear was that we would build and deliver a model for managed contexts which would be quickly adopted by customers, we would then reimplement ServicedComponent and, during that process, we would discover that our initial model contained some fundamental flaws.  It’s always extremely risky to deliver key infrastructure without taking the time to build systems on top of that infrastructure to prove the concept.

So what’s our current position?  I don’t know the official word, but my sense is the following:

In the case of managed interception and AOP, we remain firmly committed to delivering on these core features.  However, we find ourselves still debating the best way to do this.

One school holds that CBO is a model which proved itself through our customers’ COM+ experiences, which has been delivered to customers, but which suffers from poor documentation and poor performance.  Given this, the solution is to put the appropriate resources into this facet of the CLR and address the documentation and performance problems.

Another school proposes that there’s an entirely different way to achieve these goals in the managed world.  This other approach takes advantage of our ability to reason about managed programs based on their metadata and IL.  And it takes advantage of our ability to generate programs on the fly, and to control binding in order to cache and amortize some of the cost of this dynamic generation.  Given this, the solution is to maintain CBO in its current form and to invest in this potentially superior approach.

To be honest, I think we’re currently over-committed on a number of other critical deliverables.  In the next release, I doubt if either of the above schools of thought will win out.  Instead, we will remain focused on some of the other critical deliverables and postpone the interception decision.  That’s unfortunate, because I would love to see the CLR expose a general-purpose but efficient extensibility mechanism to our customers.  Such a mechanism might eliminate some of the feature requests we are currently struggling with, since teams outside the CLR could leverage our extensibility to deliver those features for us.

On the other hand, there’s something to be said for letting a major feature sit and stew for a while.  We’ve gathered a lot of requirements, internally and externally, for interception.  But I think we’re still puzzling through some of the implications of the two distinctly different design approaches.
