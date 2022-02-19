---
layout: post
title: Turning off the garbage collector
permalink: turning-off-the-garbage-collector
date: 2003-04-15 12:10:00.000000000 -07:00
status: publish
type: post
published: true
---

It is not generally possible to turn off garbage collection.  However, the garbage collector won’t run unless “provoked.”  Garbage collection is triggered by:

1. Allocation

2. Explicit calls by the application to System.GC.Collect

3. Explicit calls by the application to services that implicitly trigger a GC.  For example, unloading an AppDomain will trigger at least one full GC.

4. On some operating systems, low memory notifications to the application might cause the garbage collector to run.  This is true of recent versions of Windows.

Sometimes when developers want to turn off the garbage collector, they really want to turn off the Finalizer thread.  This thread runs asynchronously to the application and at a high priority.  If the application has a time window where it doesn’t want the Finalizer thread to intrude, one approach is to drain the finalizer queue before starting this time-critical operation.  The queue can be drained by calling GC.WaitForPendingFinalizers().

Of course, this doesn't actually turn off finalization.  But it does create a window where finalization is far less likely to intrude on your application.
