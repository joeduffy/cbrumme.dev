---
layout: post
title: DLL exports
permalink: dll-exports
date: 2003-04-15 12:59:00.000000000 -07:00
status: publish
type: post
published: true
---

People often ask how they can expose traditional DLL exports from managed assemblies.

Managed C++ makes it very easy to export functions.  And you could use tricks like ILDASM / ILASM to inject DLL exports into managed assemblies built with other languages like C#.

However, there is a fundamental mismatch between the process-wide notion of exported DLLs and the AppDomain-scoped notion of managed methods.  This mismatch results in some ambiguity when a thread calls from unmanaged to managed via one of these exports.  After all, the same method might exist in multiple AppDomains.

In V1, the CLR remembers the AppDomain which initially loaded the assembly containing the exports.  Subsequent calls from unmanaged will always return to this AppDomain.  This has the nice property that the unmanaged DLL state and the managed assembly state are 1:1 matched.  However, it’s not always the best choice.  In particular, if an ASP.NET scenario unloads the original AppDomain (perhaps because the config file or some other part of the application was updated), then no further transitions from unmanaged code can succeed.

In the latest version of the CLR, there’s another option.  The CLR can look back at the thread’s stack to determine which AppDomain the thread is running in.  Any call into managed code via one of these DLL exports can be directed to this AppDomain.  This choice works well for simple call-out / call-back-in scenarios.  But it works less well if thread switching is happening on the unmanaged side (for example, a COM apartment transition or use of the operating system’s thread-pool).  In those cases, the thread that calls into managed code isn’t directly related to the thread that called out from managed code.  Threads which have no “history” are considered to be executing in the Default AppDomain.  As a further twist, if the AppDomain that’s selected hasn’t already loaded the assembly containing the exported method, then the call will be failed.

The most current Managed C++ compiler gives the developer control over whether the V1 behavior or the new history-based behavior is used.

Note that there can be no ambiguity with AppDomain selection when using COM Interop or marshaled delegates.  In both of those cases, a managed object guides the unmanaged calls to the AppDomain where the managed object lives.  This is a sound reason for avoiding DLL exports.

Another reason for avoiding DLL exports from managed code has to do with binding.  When managed binding occurs (i.e. AssemblyRefs are chased, or Assembly.Load() is called), Fusion applies various policy statements when deciding what bits to load.  But when DLL exports trigger a load, the operating system loader ignores all the managed policy.  Therefore it’s possible that binding through DLL exports might result in a different choice of which bits to load.

Finally, the existence of DLL exports on a managed assembly causes the security system to treat the assembly differently.  An export is one of the constructs which requires that your assembly be highly trusted if it is to be loaded.

The bottom line is that DLL exports are missing from languages like C# for good reason.
