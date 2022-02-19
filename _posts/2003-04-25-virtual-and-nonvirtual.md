---
layout: post
title: Virtual and non-virtual
permalink: virtual-and-nonvirtual
date: 2003-04-25 14:42:00.000000000 -07:00
status: publish
type: post
published: true
---

The CLR type system supports both virtual and non-virtual instance methods.  And IL can contain both CALLVIRT and CALL instructions.  So it makes sense that IL generators would call virtual methods using CALLVIRT and call non-virtual instance methods with CALL.  In fact, this is not necessarily the case.  Either kind of call instruction can be applied to either kind of instance method, resulting in four distinct semantics.

Before we look at each of those four cases, we need to look at what a general call (CALL or CALLVIRT) looks like in the IL stream:

```
0x68 0x06000007   // call method
0x6f 0x06000007   // callvirt method
```

Well, that’s not too instructive.  There’s just an opcode for the call, followed by a MethodRef or MethodDef token for the method.  Generally you will see a MethodDef if the method is defined in the same assembly as the callsite, though IL generators aren’t required to make this optimization.

A better way to look at this is through ILDASM:

```
call       instance string callstyle.B::m()
callvirt   instance string callstyle.B::m()
```

ILDASM has chased the token down for you and recovered some information from it.  This consists of the name of the method, the signature & calling convention of the method, and a class where that method may be found.

It’s this class hint that’s the most interesting.  Alarm bells may be going off in your head.  How can I make a virtual call (where the override should be determined by the actual type of the receiver) if the IL stream statically declares the method to call?  This isn’t a concern.  The purpose of the class hint is to indicate the contract of the virtual call, rather than the actual override.  If you think in terms of VTables, it selects the slot rather than the method body.

In fact, this class hint is still a hint in the CALL (non-virtual) case.  The class that’s mentioned might not even implement this method directly.  So long as this class or a base class has the method, the bind attempt will succeed.

Why would an IL generator mention a method on a class, when the class doesn’t implement that method directly?  If the callsite and the target are in the same assembly, there’s little reason to do so.  But if multiple assemblies are involved, versioning can intrude.  The IL generator might mention a method on a class, but the method could move up to a superclass in a subsequent version.  And in the case of chaining calls to virtual methods up the hierarchy (e.g. ‘base’ calls in C#), the IL generator should probably mention the immediate base class in order to increase version resiliency.

In the face of metadata directives like newslot (e.g. the way C# distinguishes between ‘virtual’, ‘new’ and ‘overrides’ keywords), some of the versioning issues become quite tricky.  Each language needs to define what kinds of edits are breaking and which ones are tolerated.  Based on this, the IL generator can make sane decisions about how to emit class hints in call instructions.

So, to recap, the CALL or CALLVIRT instruction gives us a token which gives us the name, signature, calling convention, and class hint for the method contract to target.  Then a search is made upwards from the class hint, until we find an actual method definition.  Now the contract is known.

Determination of the contract could happen at JIT time or class loading time.  It can be hoisted far above the actual call.

If the call has non-virtual semantics, discovering the contract also reveals the actual method definition to execute.  If the call has virtual semantics, we cannot know the actual method definition to execute until the call happens.  At that time, we are given the object to invoke on, so we can use that object’s actual type to select the appropriate method body.

Finally we can explain all four legal combinations of CALL / CALLVIRT instructions on virtual / non-virtual methods.

* CALLVIRT on a virtual instance method. This is the normal virtual dispatch.  Given the contract and the receiver, at call-time we select the appropriate override and dispatch the call.

* CALL on a non-virtual instance method. This is the normal non-virtual dispatch.  When we discovered the contract, we discovered the appropriate method implementation.  Dispatch the call to it.

* CALL on a virtual instance method. This is a scoped (non-virtual) call.  An example is a ‘base’ call in C# where one virtual method is calling the inherited implementation.  If it used virtual semantics for this call, an infinite recursion would result.  This kind of call is available more generally via the scope resolution operator ‘::’ in C++.

* CALLVIRT on a non-virtual instance method. This is the most surprising one.  Why would someone make a virtual call when the selection of the method body doesn’t depend on dynamically discovering the type of the receiver?  There are two reasons.

    1. Some languages allow non-virtual methods to become virtual in subsequent versions of a type.  If callers are already performing virtual dispatch, they might arguably tolerate this change better.

    2. The JIT performs an important side effect when making virtual calls on non-virtual instance methods.  It ensures that the receiver is not null.  In the case of the current X86 JIT where EAX is scratch and ‘this’ is in ECX, you’ll see code like “mov eax, [ecx]” right before the call.  This moves the exception out of some random point in the method body and delivers it at the callsite.  If you look at C#’s use of this, they will suppress subsequent calls on ‘this’ so that only the outer skin of non-virtual instance methods receive this treatment.  It’s a good heuristic, though obviously it can be thwarted if the outer caller is using an IL generator that doesn’t follow this convention.

Nothing is ever simple.
