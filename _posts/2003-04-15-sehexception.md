---
layout: post
title: What is SEHException?
permalink: sehexception
date: 2003-04-15 13:31:00.000000000 -07:00
status: publish
type: post
published: true
---

One way you get this exception is if unmanaged code does an OS RaiseException() or causes a fault.  If that exception is propagated up the stack to managed code, we will try to map it to a managed exception.  For example, STATUS_NO_MEMORY maps to OutOfMemoryException and STATUS_ACCESS_VIOLATION maps to NullReferenceException.

For all the exception codes that don’t have a predefined mapping, we wrap them up into SEHException.
