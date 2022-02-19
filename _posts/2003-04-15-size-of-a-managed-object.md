---
layout: post
title: Size of a managed object
permalink: size-of-a-managed-object
date: 2003-04-15 13:11:00.000000000 -07:00
status: publish
type: post
published: true
---

We don't expose the managed size of objects because we want to reserve the ability to change the way we lay these things out.  For example, on some systems we might align and pack differently.  For this to happen, you need to specify tdAutoLayout for the layout mask of your ValueType or Class.  If you specify tdExplicitLayout or tdSequentialLayout, the CLR’s freedom to optimize your layout is constrained.

If you are curious to know how big an object happens to be, there are a variety of ways to discover this.  You can look in the debugger.  For example, Strike or SOS (son-of-strike) shows you how objects are laid out.  Or you could allocate two objects and then use unverifiable operations to subtract the addresses.  99.9% of the time, the two objects will be adjacent.  You can also use a managed profiler to get a sense of how much memory is consumed by instances of a particular type.

But we don't want to provide an API, because then you could form a dependency over this implementation detail.

Some people have confused the System.Runtime.InteropServices.Marshal.SizeOf() service with this API.  However, Marshal.SizeOf reveals the size of an object after it has been marshaled.  In other words, it yields the size of the object when converted to an unmanaged representation.  These sizes will certainly differ if the CLR’s loader has re-ordered small fields so they can be packed together on a tdAutoLayout type.
