---
layout: post
title: Hyper threading
permalink: hyper-threading
date: 2003-04-15 12:22:00.000000000 -07:00
status: publish
type: post
published: true
---

If the operating system schedules multiple threads against a hyper-threaded CPU, the CLR automatically takes advantage of this.  This is certainly the case for new versions of the OS like Windows Server 2003.

Also, the CLR did work to properly spin on a hyper threaded system.  If you are writing your own spinlocks in managed code, be sure to use Thread.SpinWait so that you get the same benefits.

We also tune subsystems like the scalable server GC so that they make sensible decisions for hyper threading.
