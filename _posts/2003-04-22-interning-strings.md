---
layout: post
title: Interning Strings and immutability
permalink: interning-strings
date: 2003-04-22 18:16:00.000000000 -07:00
status: publish
type: post
published: true
---

Managed strings are subject to ‘interning’.  This is the process where the system notices that the same string is used in several places, so it can fold all the references to the same unique instance.

Interning happens two ways in the CLR.

1. It happens when you explicitly call System.String.Intern().  Obviously the string returned from this service might be different from the one you pass in, since we might already have an intern’ed instance that has been handed out to the application.

2. It happens automatically, when you load an assembly.  All the string literals in the assembly are intern’ed.  This is expensive and – in retrospect – may have been a mistake.  In the future we might consider allowing individual assemblies to opt-in or opt-out.  Note that it is always a mistake to rely on some other assembly to have implicitly intern’ed the strings it gives you.  Through versioning, that other assembly might start composing a string rather than using a literal.

One thing that might not be immediately obvious is that we intern strings across all AppDomains.  That’s because assemblies can be loaded as domain-neutral.  When this happens, we execute the same code bytes at the same address in all AppDomains into which that assembly has been loaded.  Since we can burn the addresses of string literals into our native code as immediate data, we clearly benefit from intern’ing across all AppDomains rather than using per-AppDomain indirections in the code.  However, this approach does add overhead to intern’ing: we are forced to use per-AppDomain reference counts into a shared intern’ing table, so that we can unload intern’ed strings accurately when the last AppDomain using them is itself unloaded.

Normally, strings should be compared with String.Equals and similar mechanisms.  Note that the String class defines operator== to be String.Equals.  However, if two strings are both known to have been intern’ed, then they can be compared directly with a faster reference check.  In other words, you could call Object.operator==() rather than String.operator==().  This is only recommended for highly performance-sensitive scenarios when you really know what you are doing.

Of course, string intern’ing only works if strings are immutable.  If they were mutable, then the sharing of strings that is implicit in intern’ing would corrupt all kinds of application assumptions – as we will see.

The good news is that strings are immutable… mostly.  And they are immutable for many good reasons that have nothing to do with intern’ing.  For example, immutable strings eliminate a whole host of multi-threaded race conditions where one thread uses a string while another string mutates it.  In some cases, those race conditions could be used to mount security attacks.  For example, you could satisfy a FileIOPermission demand with a string pointing to an innocuous section of the file system, and then use another thread to quickly change the string to point to a sensitive file before the underlying CreateFile occurs.

So how can strings be mutated?

Well, you can certainly use C#’s ‘unsafe’ feature or equivalent unverifiable ILASM or Managed C++ code to write into a string’s buffer.  In those cases, some highly trusted code is performing some clearly dirty operations.  This case isn’t going to happen by accident.

A more serious concern comes with marshaling.  Here’s a program that uses PInvoke to accidentally mutate a string.  Since the string happens to have been intern’ed, it has the effect of changing a string literal in an unrelated part of the application.  We pass ‘computerName’ to the PInvoke, but ‘otherString’ gets changed too!

```
using System;
using System.Runtime.InteropServices;

public class Class1
{
    static void Main(string[] args)
    {
        String computerName = "strings are always immutable";
        String otherString = "strings are always immutable";

        int len = computerName.Length;
        GetComputerName(computerName, ref len);

        Console.WriteLine(otherString);
    }

    [DllImport("kernel32", CharSet=CharSet.Unicode)]
    static extern bool GetComputerName(
        [MarshalAs (UnmanagedType.LPWStr)] string name,
        ref int len);
}
```

And here’s the same program written to avoid this problem:

```
using System;
using System.Runtime.InteropServices;

public class Class1
{
    static void Main(string[] args)
    {
        String computerName = "strings are always immutable";
        String otherString = "strings are always immutable";

        int len = computerName.Length;
        GetComputerName(ref computerName, ref len);

        Console.WriteLine(otherString);
    }

    [DllImport("kernel32", CharSet=CharSet.Unicode)]
    static extern bool GetComputerName(
        [MarshalAs(UnmanagedType.VBByRefStr)]
        ref string name,
        ref int len);
}
```

In this second case, VBByRefStr is used for the marshaling directive.  The argument is treated as ‘byref’ on the managed side, but remains ‘byval’ on the unmanaged side.  If the unmanaged side scribbles into the buffer, it won’t pollute the managed string, which remains immutable.  Instead, a different string is back-propagated to the managed side, thereby preserving managed string immutability.

If you are coding in VB, you can pretend that the VBByRefStr is actually byval on the managed side.  The compiler works its magic on your behalf, so you don’t actually realize that you now have a different string.  C# works no such magic, so I had to explicitly add the ‘ref’ keyword in all the right places.

If you’re like me, you probably find all the marshaling directives bewildering.  I can’t recommend Adam Nathan’s book enough.  It is “.NET and COM – The Complete Interoperability Guide”.  It truly is the bible for interop.

Nevertheless, even with the book it’s easy to make a lot of mistakes.  There’s a feature in the new CLR release called Customer Debug Probes.  It makes finding certain kinds of bugs much easier.  Fortunately for all of us, it’s particularly geared to finding bugs with marshaling and other Interop issues.
