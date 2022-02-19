---
layout: post
title: Surprising 'protected' behavior
permalink: surprising-protected-behavior
date: 2003-04-15 13:35:00.000000000 -07:00
status: publish
type: post
published: true
---

There’s a subtle but important difference between protected access in unmanaged C++ and protected access (i.e. family) in the CLR.  The difference is due to the CLR’s ability to build security guarantees on top of type safety.

Imagine you had a bifurcated hierarchy:

```
       Class A { protected M }
       /                \
Class G : A           Class X : A
```

There is no relationship between X and G, except for the fact that they both derive from A.  We don’t allow X to access A.M on instances of type G and we don’t allow G to access A.M on instances of type X.  Instead, X can only access A.M on instances of X and instances that are subtypes of X.

The most efficient way for us to enforce this is to require a cast to X before accessing A.M from any of X’s methods.  Of course, we only require this in verifiable code.
