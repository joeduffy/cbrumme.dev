---
layout: post
title: Value types
permalink: value-types
date: 2003-05-10 18:33:00.000000000 -07:00
status: publish
type: post
published: true
---

The CLR’s type system includes primitive types like signed and unsigned integers of various sizes, booleans and floating point types.  It also includes partial support for types like pointers and function pointers.  And it contains some rather exotic beasts, like ArgIterators and TypedByRefs.  (These are exotic because their lifetimes are restricted to a scope on the stack, so they can never be boxed, embedded in a class, or otherwise appear in the GC heap).  Lastly, but most importantly, the type system includes interfaces, classes and value types.

In fact, if you look at our primitive types the right way, they’re really just some value types that are so popular and intrinsic that we gave them special encoding in our type signatures and instructions.

The CLR also supports a flexible / weak kind of enumeration.  Our enums are really just a specialization of normal value types which conform to some extra conventions.  From the CLR’s perspective, enums are type distinct aliases that otherwise reduce to their underlying primitive type.  This is probably not the way anyone else thinks of them, so I’ll explain in more detail later.

Anyway as we’ve seen our type system has value types all over the place – as structs, enums, and primitive scalars.  And there are some rather interesting aspects to their design and implementation.

The principal goal of value types was to improve performance over what could be achieved with classes.  There are some aspects of classes which have unavoidable performance implications:

1. All instances of classes live in the GC heap.  Our GC allocator and our generation 0 collections are extremely fast.  Yet GC allocation and collection can never be as fast as stack allocation of locals, where the compiler can establish or reclaim an entire frame of value types and primitives with a single adjustment to the stack pointer. 
2. All instances of classes are self-describing.  In today’s implementation, we use a pointer-sized data slot on every instance to tag that instance’s type.  This single slot enables us to perform dynamic casting, virtual dispatch, embedded GC pointer reporting and a host of other useful operations.  But sometimes you just cannot afford to burn that data slot, or to initialize it during construction.  If you have an array of 10,000 value types, you really don’t want to place that tag 10,000 times through memory – especially if dirtying the CPU’s cache in this way isn’t going to improve the application’s subsequent accesses. 
3. Instances of classes can never be embedded in other instances.  All logical embedding is actually achieved by reference.  This is the case because our object-oriented model allows “is-a” substitutability.  It’s hard to achieve efficient execution if subtypes can be embedded into an instance, forcing all offsets to be indirected.  Of course, the CLR is a virtualized execution environment so I suspect we could actually give the illusion of class embedding.  However, many unmanaged structures in Win32 are composed of structs embedded in structs.  The illusion of embedding would never achieve the performance of true embedding when blittable types are passed across the managed / unmanaged boundary.  The performance impact of marshaling would certainly weaken our illusion.

If you look at the class hierarchy, you find that all value types derive from System.Object.  Whether this is indeed true is a matter of opinion.  Certainly value types have a layout that is not an extension of the parent Object’s layout.  For example, they lack the self-describing tag.  It’s more accurate to say that value types, when boxed, derive from System.Object.  Here’s the relevant part of the class hierarchy:

```
                           System.Object
                             /       \
                            /         \
                     most classes   System.ValueType
                                        /       \
                                       /         \
                              most value types   System.Enum
                                                   \
                                                    \
                                                   all enums
```

Why do I use the term “most classes” in this hierarchy?  Because there are several classes that don’t appear in that section of the hierarchy.  System.Object is the obvious one.  And, paradoxically, System.ValueType is actually a class, rather than a value type.  Along the same lines System.Enum, despite being a subtype of System.ValueType, is neither a value type nor an enum.  Rather it’s a base class under which all enums are parented.

> Incidentally, something similar is going on with System.Array and all the array types.  In terms of layout, System.Array really isn’t an array.  But it does serve as the base class under which all kinds of arrays (single-dimension, multi-dimension, zero-lower-bounds and non-zero-lower-bounds) are parented.

Now is probably a good time to address one of the glaring differences between the ECMA spec and our implementation.  According to the ECMA spec, it should be possible to specify either a boxed or an unboxed value type.  This is indicated by using either ELEMENT_TYPE_VALUETYPE &lt;token&gt; or ELEMENT_TYPE_CLASS &lt;token&gt;.  By making this distinction, you could have method arguments or array elements or fields that are of type “boxed myStruct”.  The CLR actually implemented a little of this, and then cut the feature because of schedule risk.  Presumably we’ll implement it properly some day, to achieve ECMA conformance.  Until then, we will refuse to load applications that attempt to specify well-typed boxed value types.

I mentioned earlier that the CLR thinks of enums rather differently than the average developer.  Inside the CLR, an enum is a type-distinct alias.  We generally treat the enum as an alias for the underlying integral type that is the type of the enum’s \_\_value field.  This alias is type-distinct because it can be used for overloading purposes.  A class can have three methods that are distinguished only by the fact that they one takes MyEnum vs. YourEnum vs. the underlying integral type as an argument.

Beyond that, the CLR should not attach any significance to the enum.  In particular, we do no validation that the values of the enum ever match any of the declared enumerands.

I say the CLR “should not” attach any significance, but the model shows some rough edges if you look closely.  When an enum is unboxed and is in its value type form, we only have static type information to guide us.  We tend to discard this static typing information and reduce the type to its underlying integral type.  You can actually assign a value of MyEnum to a variable of type YourEnum, as far as the JIT and verifier are concerned.  But as soon as an enum is boxed, it becomes self-describing.  At that point, cast operations and covariant array typechecks tend to be picky about whether you’ve got a boxed MyEnum or a boxed YourEnum.  As one of the architects of the C# compiler remarked, “Enums are treated exactly like their underlying types, except when they aren’t.”  This is unfortunate and ideally we should clean this up some day.

While we’re on the subject of using enums to create distinct overloads, it makes sense to mention custom signature modifiers.  These modifiers provide an extensibility point in the type system which allows sophisticated IL generators to attach significance to types.  For example, I believe Managed C++ expresses their notion of ‘const’ through a custom signature modifier that they can attach to method arguments.  Custom signature modifiers come in two forms.  In the first form, they simply create enough of a difference between otherwise identical signatures to support overloading.  In their second form, they also express some semantics.  If another IL generator doesn’t understand those semantics, it should not consume that member.

So an IL generator could attach custom signature modifiers to arguments of an integral type, and achieve the same sort of type-distinct aliasing that enums provide.

Today, custom signature modifiers have one disappointing gap.  If you have a method that takes no arguments and returns void, there isn’t a type in the signature that you can modify to make it distinct.  I don’t think we’ve come up with a good way to address this yet.  (Perhaps we could support custom signature modifier on the calling convention?)

Back to value types.  Instance methods, whether virtual or non-virtual, have an implicit ‘this’ argument.  This argument is not expressed in the signature.  Therefore it’s not immediately obvious that a method like “void m(int)” actually has a different true signature depending on whether the method appears on a class or on a value type.  If we add back the implicit ‘this’ for illustration purposes, the true signatures are really:

```
void m( [    MyClass  this], int arg)
void m( [ref MyStruct this], int arg)
```

It’s not surprising that ‘this’ is MyClass in one case and MyStruct in the other case.  What may be a little surprising is that ‘this’ is actually a byref in the value type case.  This is necessary if we are to support mutator methods on a value type.  Otherwise any changes to ‘this’ would be through a temporary which would subsequently be discarded.

Now we get to the interesting part.  Object has a number of virtual methods like Equals and GetHashCode.  We now know that these methods have implicit ‘this’ arguments of type Object.  It’s easy to see how System.ValueType and System.Enum can override these methods, since we’ve learned that these types are actually classes rather than value types or enums.

But what happens when MyStruct overrides GetHashCode?  Somehow, the implicit ‘this’ argument needs to be ‘ref MyStruct’ when the dispatch arrives at MyStruct’s implementation.  But the callsite clearly cannot be responsible for this, since the callsite calls polymorphically on boxed value types and other class instances.  It should be clear that a similar situation can occur with any interface methods that are implemented by a value type.

Something must be converting the boxed value type into a byref to the unboxed value type.  This ‘something’ is an unboxing stub which is transparently inserted into the call path.  If an implementation uses vtables to dispatch virtual methods, one obvious way to insert an unboxing stub into the call path is to patch the vtable slot with the stub address.  On X86, the unboxing stub could be very efficient:

```
add ecx, 4    ; bias ‘this’ past the self-describing tag
jmp <target>  ; now we’re ready for the ‘ref struct’ method
```

Indeed, even the JMP could be removed by placing the unboxing stub right before the method body (effectively creating dual entrypoints for the method).

At polymorphic callsites, the best we can do is vector through a lightweight unboxing stub.  But in many cases the callsite knows the exact type of the value type.  That’s because it’s operating on a well-typed local, argument, or field reference.  Remember that value types cannot be sub-typed, so substitutability of the underlying value type is not a concern.

This implies that the IL generator has two code generation strategies available to it, when dispatching an interface method or Object virtual method on a well-typed value type instance.  It can box it and make the call as in the polymorphic case.  Or it can try to find a method on the value type that corresponds to this contract and takes a byref to the value type, and then call this method directly.

Which technique should the IL generator favor?  Well, if the method is a mutator there may be a loss of side effects if the value type is boxed and then discarded; the IL generator may need to back-propagate the changes if it goes the boxing route.  Also, boxing is an efficient operation, but it necessarily involves allocating an object in the GC heap.  So the boxing approach can never be as fast as the ‘byref value type’ approach.

So why wouldn’t an IL generator always favor the ‘byref value type’ approach?  One disadvantage is that finding the correct method to call can be challenging.  In an earlier blog (Interface layout), I revealed some of this subtlety.  The compiler would have to consider MethodImpls, whether the interface is redundantly mentioned in the ‘implements’ clause, and several other points in order to predict what the class loader will do.

But let’s say our IL generator is sophisticated enough to do this.  It still might prefer the boxing approach, so it can be resilient to versioning changes.  If the value type is defined in a different assembly than the callsite, the value type’s implementation can evolve independently.  The value type has made a contract that it will implement an interface, but it has not guaranteed which method will be used to satisfy that interface contract.  Theoretically, it could use a MethodImpl to satisfy ‘I.xyz’ using a class method called ‘abc’ in one version and a method called ‘jkl’ in some future version.  In practice, this is unlikely and some sophisticated compilers predict the method body to call and then hope that subsequent versions won’t invalidate the resulting program.

Given that a class or value type can re-implement a contract in subsequent versions, consider the following scenario:

```
class Object { public virtual int GetHashCode() {…} … }
class ValueType : Object  { public override int GetHashCode() {…} … }
struct MyVT : ValueType { public override int GetHashCode() {…} …}
```

As we know, MyVT.GetHashCode() has a different actual signature, taking a ‘ref MyVT’ as the implicit ‘this’.  Let’s say an IL generator takes the efficient but risky route of generating a call on a local directly to MyVT.GetHashCode.  If a future version of MyVT decides it is satisfied with its parent’s implementation, it might remove this override.  If value types weren’t involved, this would be an entirely safe change.  We already saw in one of my earlier blogs (Virtual and non-virtual) that the CLR will bind calls up the hierarchy.  But for value types, the signature is changing underneath us.

Today, we consider this scenario to be illegal.  The callsite will fail to bind to a method and the program is rejected as invalid.  Theoretically, the CLR could make this scenario work.  Just as we insert unboxing stubs to match an ‘Object this’ callsite to a ‘ref MyVT this’ method body, we could also create and insert reboxing stubs to match a ‘ref MyVT’ callsite to an ‘Object this’ method body.

This would be symmetrical.  And it’s the sort of magic that you would naturally expect a virtual execution environment like the CLR to do.  As with so many things, we haven’t got around to even seriously considering it yet.
