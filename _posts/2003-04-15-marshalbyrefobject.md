---
layout: post
title: Inheriting from MarshalByRefObject
permalink: marshalbyrefobject
date: 2003-04-15 14:22:00.000000000 -07:00
status: publish
type: post
published: true
---

Developers often wonder why they are forced to derive from MarshalByRefObject or EnterpriseServices.ServicedComponent.  It would be so much more convenient if they could add a CustomAttribute to their class or use a marker interface to declare that they want to be marshaled by reference or they want serviced behavior.

The reason has to do with performance.  The CLR has a large number of optimizations which it can apply to objects that are guaranteed to be local.  If the object is possibly remote, then these optimizations are invalidated.  Examples include method inlining by the JIT, direct field access, fast instantiation in the local heap, direct method invocation for non-virtuals and more efficient type tests like cast operations.

When the benefit of these optimizations is considered, it completely outweighs the programming model impact to the inheritance hierarchy.  This decision is key to achieving our long term goal of performance parity with native code.
