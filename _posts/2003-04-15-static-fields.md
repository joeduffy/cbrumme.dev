---
layout: post
title: Static Fields
permalink: static-fields
date: 2003-04-15 11:41:00.000000000 -07:00
status: publish
type: post
published: true
---

By default, static fields are scoped to AppDomains.  In other words, each AppDomain gets its own copy of all the static fields for the types that are loaded into that AppDomain.  This is independent of whether the code was loaded as domain-neutral or not.  Loading code as domain neutral affects whether we can share the code and certain other runtime structures.  It is not supposed to have any effect other than performance.

Although per-AppDomain is the default for static fields, there are 3 other possibilities:

RVA-based static fields are process-global.  These are restricted to scalars and value types, because we do not want to allow objects to bleed across AppDomain boundaries.  That would cause all sorts of problems, especially during AppDomain unloads.  Some languages like ILASM and MC++ make it convenient to define RVA-based static fields.  Most languages do not.

Static fields marked with System.ThreadStaticAttribute are scoped per-thread per-AppDomain.  You get convenient declarative thread-local storage over and above the normal per-AppDomain cloning of static fields.

Static fields marked with System.ContextStaticAttribute are scoped per-context per-AppDomain.  If you are using managed contexts and ContextBoundObject, this is a convenient way to get storage cloned in each managed context.

We considered (briefly) building thread-relative and context-relative versions of the existing .cctor class constructor.  But that’s a lot of machinery to ensure that all static fields are initialized via a constructor that is coordinated by the system.

Instead, our docs recommend against initializing your thread-relative and context-relative static fields in a .cctor.  The reason is that a .cctor executes only once per AppDomain.  The static fields will get initialized in whatever thread and context the .cctor happens to run in.  But all subsequent threads and contexts will have uninitialized data.

So the model you have today is that you should be prepared to initialize your thread-relative and context-relative statics on first use.  This is fairly easy to do since we guarantee these statics are first initialized to 0.  So you can use a thread-relative or context-relative static Boolean field (inited to false) or static Object reference (inited to null) to indicate that initialization hasn’t occurred yet.
