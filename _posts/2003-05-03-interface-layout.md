---
layout: post
title: Interface layout
permalink: interface-layout
date: 2003-05-03 18:56:00.000000000 -07:00
status: publish
type: post
published: true
---

The CLR has two different techniques for implementing interfaces.  These two techniques are exposed with distinct syntax in C#:

```
interface I { void m(); }
class C : I {
   public virtual void m() {} // implicit contract matching
}
class D : I {
   void I.m() {}              // explicit contract matching
}
```

At first glance, it may seem like the choice between these two forms is a stylistic one.  However, there are actually deep semantic differences between the two forms.

(C# has at least one other place where a choice of semantics is encoded in what seems to be a stylistic choice.  A class constructor can be expressed in C# either as a static constructor method, or as assignments in a set of static field declarations.  Depending on this stylistic choice, the class will or will not be marked with tdBeforeFieldInit.  This mark – shown as beforefieldinit in ILDASM – affects the semantics of when the .cctor method will be executed by the CLR.  This also results in performance differences, particularly in situations like NGEN or domain-neutral code.)

In class C, we get a public class method ‘m’ that does double duty as the implementation of the interface method.  This is all pretty vanilla:

```
.method public hidebysig newslot virtual instance void  m() cil managed
{
  // Code size       1 (0x1)
  .maxstack  0
  IL_0000:  ret
} // end of method C::m
```

But in class D, we see something quite different:

```
.method private hidebysig newslot virtual final instance void  I.m() cil managed
{
  .override I::m
  // Code size       1 (0x1)
  .maxstack  0
  IL_0000:  ret
} // end of method D::I.m
```

There are several surprising things about this case:

1. The method is introduced (newslot) with the bizarre incantation of virtual, private and final.
2. The name of the method isn’t even ‘m’.  It is ‘I.m’.
3. There is a mysterious ‘override’ clause associated with the method body.

The method is marked as virtual because the CLR can only implement interface contracts using virtual members.  There’s a bit of a debate on our team whether this is an architectural requirement or an implementation detail.  At this point, we’re comfortable that we could remove this restriction without much work.  However, we have to consider the ECMA standard, the impact on other CLI implementations like Compact Frameworks, the effect on the various languages targeting the compiler, and some interesting effects on existing applications.  We might be saddled with this rule indefinitely.

At the language level, C# allows non-virtuals to implement interface contracts.  How do they get around the CLR restriction?  Well, if the class that introduces the non-virtual is in the same assembly as the class that uses that method to implement the interface contract, C# quietly defines the base class’ method as virtual.  If the base class that introduced the non-virtual is in a different assembly, then C# generates a virtual thunk in the subtype which delegates to the non-virtual base method.

Getting back to our example, I.m is declared as private because it is not available for calling via the class.  It can only be called via the interface.

I.m is declared as final because C# really doesn’t want to mark the method as virtual.  This was forced on them by the architectural decision / implementation restriction that interface contracts can only be implemented by virtual methods.

As for the name, C# could have picked anything that’s a legal identifier.  This member isn’t available for external binding, since it is private to the class and only accessible through the interface.

Since the name ‘I.m’ is insignificant, obviously this isn’t what tells the CLR loader to use this method to satisfy the interface contract.  In fact, it’s that mysterious ‘override’ clause.  This is what’s known as a MethodImpl.  It should not be confused with System.Runtime.CompilerServices.MethodImplAttribute, which controls a method’s eligibility for inlining, its synchronization behavior and other details.

A MethodImpl is a statement in the metadata that matches a method body to a method contract.  Here it is used to match the body I.m with the interface contract I::m.  Generally, you will see MethodImpls used in this way to match methods to interfaces.  But MethodImpls can be used to match any method body to any contract (e.g. a class virtual slot) provided that:

1. The contract is virtual
2. The body is virtual
3. The body and the MethodImpl are defined on the same class
4. The contract is defined either on this class or somewhere up the hierarchy (including implemented interfaces).

Once again, it’s open to debate whether MethodImpls require virtual contracts and bodies for sound architectural reasons or for temporary implementation reasons.

The ECMA spec contains the rules for how interface contracts are satisfied by class methods.  This explains how the base class’ layout can be at least partially re-used, and it explains the precedence of the two techniques we’ve seen above (class methods match by name and signature vs. MethodImpls which match methods of any name that have the correct signature).

It also mentions one other surprising detail of interface layout.  In the example below, we would expect Derived and Redundant to have the same layout.  Sure, there’s a redundant mention of interface I on class Redundant, but that seems irrelevant.

```
interface I { void m(); }
class A : I {
   public virtual void m() {}
}

class Derived : A {
   public new virtual void m() {}
}

class Redundant : A, I {
   public new virtual void m() {}
}
```

In fact, it is highly significant.  Class A has already satisfied the interface contract for I.  Class Derived simply inherits that layout.  The new method Derived.m is unrelated to I.m.  But in class Redundant, we mention interface I in the implements list.  This causes the CLR loader to satisfy the interface contract all over again.  In this new layout, Redundant.m can be used to satisfy I.m.

If you’re thinking that some of this stuff is pretty subtle, you are right.  Normally, developers wouldn’t concern themselves with the different ways that the CLR can satisfy interface contracts.  Instead, you would happily code to your language rules and you would trust your IL generator to spit out the appropriate metadata.  In fact, one of the reasons we have all these subtle rules in the CLR is so we can accommodate all the different language rules that we encounter.
