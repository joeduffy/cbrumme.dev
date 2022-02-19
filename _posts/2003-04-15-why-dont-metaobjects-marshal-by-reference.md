---
layout: post
title: Why don't metaobjects marshal by reference?
permalink: why-dont-metaobjects-marshal-by-reference
date: 2003-04-15 13:47:00.000000000 -07:00
status: publish
type: post
published: true
---

Objects that derive from MarshalByRefObject will marshal by reference rather than value.  Metaobjects like Assembly, Type and MethodInfo do not derive from MarshalByRefObject.  This is because we don’t want Type to be marshal by ref, which implies that none of the metaobjects should.

The CLR actually supports a few marshaling styles that aren’t generally available.  For example, we have some types that we “marshal by bleed” across AppDomain boundaries.  Thread objects and String objects are currently in this category.

Type objects marshal in their own distinct way.  We take the type identity in one AppDomain and then resolve that identity on the other side.  This may or may not end up with the same type.  In fact, the type may not even be loadable on the other side.  If it is loadable, it might be a different version.  Or it might be the same logical type, but with its own Type instance.  If the type was loaded AppDomain-neutral (i.e. shared code) then we may even use the exact same managed Type instance.

We went down this pathway in part because we wanted managed remoting to ignore statics.  If we remoted statics, languages would have to use an instance to indicate which remote static set to access.  In other words, statics would become funny instance members.  It’s hard to imagine how this might be expressed in languages.

```
AppDomain ad = …;
Class XYZ { public static int foo() {…} public static int bar; }

[ad]XYZ.bar = [ad]XYZ.foo();
```

Rather than making AppDomains become part of the compilation environment of all managed languages, we preferred to make the developer do the proxy work explicitly.
