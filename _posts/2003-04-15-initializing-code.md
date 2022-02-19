---
layout: post
title: Initializing code
permalink: initializing-code
date: 2003-04-15 17:24:00.000000000 -07:00
status: publish
type: post
published: true
---

A common question is how to initialize code before it is called.  In the unmanaged world, this is done with a DLL_PROCESS_ATTACH notification to your DllMain routine.  Managed C++ can actually use this same technique.  However, it has all the usual restrictions and problems related to the operating system’s loader lock.  This approach is not recommended for managed code.

However, we don’t have a good assembly-level or module-level replacement for this technique.

One possible option is to hook up to the AppDomain AssemblyLoad event.  This is great for telling you when other code has loaded.  But there’s a chicken and egg problem with initializing your own code with this technique.  You can’t register for the event before you’ve loaded and initialized!

Another option is to use a static constructor (aka class constructor method.  This is given the cryptic name .cctor in the metadata.  However, a .cctor only gets invoked prior to usage of the class that it is declared on.  So you would have to add one to every class in your assembly... and you still wouldn't be able to trap all usage of e.g. ValueTypes in your assembly.

If you go this route, be careful about the different semantics the CLR associates with .cctor methods, based on whether the tdBeforeFieldInit bit is set.  When this bit is set, we can be more efficient.  But we won't trap any accesses to your class except to static fields.  When this bit is reset, your .cctor will execute before any instance or static method or field is accessed.  However, the CLR must then give up on various optimizations.  The impact can be particularly painful with code that is loaded as domain-neutral (i.e. shared across AppDomains).

How do you know whether the bit is set or not?  Your language is setting it one way or the other on your behalf.  I believe C# will set tdBeforeFieldInit if you just have initialization statements for your static fields.  If you have an explicit static constructor method, they will reset this bit.  It’s easy enough to check with ILDASM.

Neither of the above solutions is particularly satisfying.  The CLR is under some pressure from various language partners and other developers to provide a module-level equivalent to a class constructor.

While we are on the subject of .cctor’s, there are a couple of other interesting facts:

Some languages require that base class .cctor methods will run before derived class .cctors.  Or that interface .cctor methods will run before the .cctors of the classes that implement those methods.  The CLR has no such rules for chaining (though it does have some important rules for managing circular references between .cctors of different types).  So there’s a service called System.Runtime.CompilerServices.RuntimeHelpers.RunClassConstructor which your language might call to explicitly trigger execution of base .cctor methods for this purpose.

Any use of a .cctor has some impact on system performance.  And, depending on the semantics of the .cctor (tdBeforeFieldInit), whether the code is domain-neutral, whether the code is NGEN’d, whether chaining is involved, etc., this cost can be measurable.  Only use .cctor’s if you need them (duh).

One common use of a .cctor is to initialize a large array of scalars.  Doesn’t it seem like a huge waste to use code to laboriously assign each array element – and then never use that code again?  In the unmanaged world, you would place the data into the image as initialized data and avoid any code execution.

We can’t quite achieve such perfection with managed code, because the resulting managed array must be allocated in the GC heap.  However, there is a way to efficiently load up a managed array with static scalar data.  The technique is based on a service in System.Runtime.CompilerServices.RuntimeHelpers called InitializeArray(Array array, RuntimeFieldHandle fldHandle).  This service allows you to pass in a reference to a managed array and the handle of a field in metadata.  The field must be RVA-based.  In other words, it must be associated with an address in the image which presumably contains the scalar data.  You are only permitted to copy as many bytes as the metadata declares are associated with this field.

Clearly this isn’t something you can take advantage of directly.  But your language compiler will ideally notice cases where the array size exceeds some threshold.  I’m aware of at least one popular managed compiler that will use this technique on your behalf.

Finally, a .cctor method will execute at most one time in any AppDomain.  If it fails to complete successfully, it cannot be restarted.  That’s because it contains arbitrary code, with arbitrary side effects.  If an exception escapes out of a .cctor execution, it is captured and latched as the InnerException of a TypeInitializationException.  Subsequent attempts to use that type in the same AppDomain may trigger another attempted execution of the .cctor (depending on tdBeforeFieldInit of course).  When this happens, the TypeInitializationException will be thrown again.  The type can never be initialized in this AppDomain.

One day, it would be nice if we could distinguish restartable .cctor methods from non-restartable ones.  Until then, be careful not to allow exceptions to escape your .cctor method unless the type really is off limits.
