---
layout: post
title: Managed objects and COM
permalink: managed-objects-and-com
date: 2003-04-15 14:14:00.000000000 -07:00
status: publish
type: post
published: true
---

All managed objects other than those derived from ServicedComponent, when exposed to COM, behave as if they have aggregated the free threaded marshaler (FTM).  In other words, they can be called on any thread without any cross-apartment marshaling.

Although managed objects act as if they aggregate the FTM, they don’t actually aggregate it because that would be inefficient.  Instead, the CLR implements IMarshal on behalf of all managed objects that don’t provide their own implementation.  The IMarshal implementation we provide is similar to the one the FTM would do.

If a managed object implements its own IMarshal, it should be aware of a quirk of OLE32 on some versions of the operating system.  The IStream argument passed by OLE when calling your IMarshal interface is sometimes allocated on the stack.  So you better be done with that IStream before you return to OLE.  Of course you are done with it, but the COM Interop layer might hold onto it until a garbage collection recovers it.  To avoid the subsequent heap corruption and crash, you should explicitly call ReleaseComObject on the IStream argument before returning.

Obviously you are better off allowing the CLR to implement IMarshal on your behalf!

The exception to all this free-threaded behavior is any type that inherits from System.EnterpriseServices.ServicedComponent.  The runtime treats such objects as if they really were unmanaged COM objects.  All calls from managed clients to ServicedComponent servers will check the apartment and COM+ context.  If these don't match, the runtime pipes the call through COM so that any thread marshaling or context transitions are correctly performed.

Of course, this is a special section of the type hierarchy.  And the fact that such types obey COM rules is more of an implementation detail than it is a design point.  All other managed objects are available directly from all COM apartments and COM+ contexts.

Furthermore, AppDomains and COM apartments are completely orthogonal.
