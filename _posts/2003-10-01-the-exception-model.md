---
layout: post
title: The Exception Model
permalink: the-exception-model
date: 2003-10-01 13:18:00.000000000 -07:00
status: publish
type: post
published: true
---

I had hoped this article would be on changes to the next version of the CLR which allow it to be hosted inside SQL Server and other “challenging” environments.  This is more generally interesting than you might think, because it creates an opportunity for other processes (i.e. your processes) to host the CLR with a similar level of integration and control.  This includes control over memory usage, synchronization, threading (including fibers), extended security models, assembly storage, and more.

However, that topic is necessarily related to our next release, and I cannot talk about deep details of that next release until those details have been publicly disclosed.  In late October, Microsoft is holding its PDC and I expect us to disclose many details at that time.  In fact, I’m signed up to be a member of a PDC panel on this topic.  If you work on a database or an application server or a similarly complicated product that might benefit from hosting the CLR, you may want to attend.

After we’ve disclosed the hosting changes for our next release, you can expect a blog on hosting in late October or some time in November.

Instead, this blog is on the managed exception model.  This is an unusual topic for me.  In the past, I’ve picked topics where I can dump information without having to check any of my facts or do any research.  But in the case of exceptions I keep finding questions I cannot answer.  At the top level, the managed exception model is nice and simple.  But – as with everything else in software – the closer you look, the more you discover.

So for the first time I decided to have some CLR experts read my blog entry before I post it.  In addition to pointing out a bunch of my errors, all the reviewers were unanimous on one point: I should write shorter blogs.

Of course, we can’t talk about managed exceptions without first considering Windows Structured Exception Handling (SEH).  And we also need to look at the C++ exception model.  That’s because both managed exceptions and C++ exceptions are implemented on top of the underlying SEH mechanism, and because managed exceptions must interoperate with both SEH and C++ exceptions.

**Windows SEH**

Since it’s at the base of all exception handling on Windows, let’s look at SEH first.  As far as I know, the definitive explanation of SEH is still Matt Pietrek’s excellent 1997 article for Microsoft Systems Journal: http://www.microsoft.com/msj/0197/exception/exception.aspx.  There have been some extensions since then, like vectored exception handlers, some security enhancements, and the new mechanisms to support IA64 and AMD64.  (It’s hard to base exceptions on FS:[0] chains if your processor doesn’t have an FS segment register).  We’ll look at all these changes shortly.  But Matt’s 1997 article remains a goldmine of information.  In fact, it was very useful to the developers who implemented exceptions in the CLR.

The SEH model is exposed by MSVC via two constructs:

1. `__try {…} __except(filter_expression) {…}`
2. `__try {…} __finally {…}`

Matt’s article explains how the underlying mechanism of two passes over a chain of single callbacks is used to provide try/except/finally semantics.  Briefly, the OS dispatches an exception by retrieving the head of the SEH chain from TLS.  Since the head of this chain is at the top of the TIB/TEB (Thread Information Block / Thread Environment Block, depending on the OS and the header file you look at), and since the FS segment register provides fast access to this TLS block on X86, the SEH chain is often called the FS:[0] chain.

Each entry consists of a next or a prev pointer (depending on how you look at it) and a callback function.  You can add whatever data you like after that standard entry header.  The callback function is called with all sorts of additional information related to the exception that’s being processed.  This includes the exception record and the register state of the machine which was captured at the time of the exception.

To implement the 1st form of MSVC SEH above (__try/__except), the callback evaluates the filter expression during the first pass over the handler chain.  As exposed by MSVC, the filter expression can result in one of three legal values:

```
EXCEPTION_CONTINUE_EXECUTION = -1
EXCEPTION_CONTINUE_SEARCH = false 0
EXCEPTION_EXECUTE_HANDLER = true 1
```

Of course, the filter could also throw its own exception.  That’s not generally desirable, and I’ll discuss that possibility and other flow control issues later.

But if you look at the underlying SEH mechanism, the handler actually returns an EXCEPTION_DISPOSITION:

```
typedef enum _EXCEPTION_DISPOSITION
{
   ExceptionContinueExecution,
   ExceptionContinueSearch,
   ExceptionNestedException,
   ExceptionCollidedUnwind
} EXCEPTION_DISPOSITION;
```

So there’s some mapping that MSVC is performing here.  Part of that mapping is just a trivial conversion between the MSVC filter values and the SEH handler values.  For instance ExceptionContinueSearch has the value 1 at the SEH handler level but the equivalent EXCEPTION_CONTINUE_SEARCH has the value 0 at the MSVC filter level.  Ouch.

But the other part of the mapping has to do with a difference in functionality.  For example, ExceptionNestedException and ExceptionCollidedUnwind are primarily used by the OS dispatch mechanism itself.  We’ll see the circumstances in which they arise later.  More importantly, MSVC filters can indicate that the __except clause should run by returning EXCEPTION_EXECUTE_HANDLER.  But we shall see that at the SEH level this decision is achieved by having the exception dispatch routine fix up the register context and then resuming execution at the right spot.

The EXCEPTION_CONTINUE_EXECUTION case supports a rather esoteric use of SEH.  This return value allows the filter to correct the problem that caused the exception and to resume execution at the faulting instruction.  For example, an application might be watching to see when segments are being written to so that it can log this information.  This could be achieved by marking the segment as ReadOnly and waiting for an exception to occur on first write.  Then the filter could use VirtualProtect to change the segment containing the faulting address to ReadWrite and then restart the faulting instruction.  Alternatively, the application could have two VirtualAllocs for each region of memory.  One of these could be marked as ReadOnly and the second could be a shadow that is marked as ReadWrite.  Now the exception filter can simply change the register state of the CPU that faulted, so that the register containing the faulting address is changed from the ReadOnly segment to the shadowed ReadWrite segment.

Obviously anyone who is playing these games must have a lot of sophistication and a deep knowledge of how the program executes.  Some of these games work better if you can constrain the code that’s generated by your program to only touch faulting memory using a predictable cliché like offsets from a particular register.

I’ll talk about this kind of restartable or resumable exception in the context of managed code later.  For now, let’s pretend that the filter either returns “true – I would like my ‘except’ clause to handle this exception” or “false – my ‘except’ clause is uninterested in this exception”.  If the filter returns false, the next SEH handler is fetched from the chain and it is asked this same question.

The OS is pretty paranoid about corrupt stacks during this chain traversal.  It checks that all chain entries are within the bounds of the stack.  (These bounds are also recorded in the TEB).  The OS also checks that all entries are in ascending order on the stack.  If you violate these rules, the OS will consider the stack to be corrupt and will be unable to process exceptions.  This is one of the reasons that a Win32 application cannot break its stack into multiple disjoint segments as an innovative technique for dealing with stack overflow.

Anyway, eventually a handler says “true – I would like my ‘except’ clause to handle this exception”.  That’s because there’s a backstop entry at the end of the chain which is placed there by the OS when the thread is created.  This last entry wants to handle all the exceptions, even if your application-level handlers never do.  That’s where you get the default OS behavior of consulting the unhandled exception filter list, throwing up dialog boxes for Terminate or Debug, etc.

As soon as a filter indicates that it wants to handle an exception, the first pass of exception handling finishes and the second pass begins.  As Matt’s article explains, the handler can use the poorly documented RtlUnwind service to deliver second pass notifications to all the previous handlers and pop them off the handler chain.

In other words, no unwinding happened as the first pass progressed.  But during the second pass we see two distinct forms of unwind.  The first form involves popping SEH records from the chain that was threaded from TLS.  Each such SEH record is popped before the corresponding handler gets called for the second pass.  This leaves the SEH chain in a reasonable form for any nested exceptions that might occur within a handler.

The other form of unwind is the actual popping of the CPU stack.  This doesn’t happen as eagerly as the popping of the SEH records.  On X86, EBP is used as the frame pointer for methods containing SEH.  ESP points to the top of the stack, as always.  Until the stack is actually unwound, all the handlers are executed on top of the faulting exception frame.  So the stack actually grows when a handler is called for the first or second pass.  EBP is set to the frame of the method containing a filter or finally clause so that local variables of that method will be in scope.

The actual popping of the stack doesn’t occur until the catching ‘except’ clause is executed.

So we’ve got a handler whose filter announced in the first pass that it would handle this exception via EXCEPTION_EXECUTE_HANDLER.  And that handler has driven the second pass by unwinding and delivering all the second pass notifications.  Typically it will then fiddle with the register state in the exception context and resume execution at the top of the appropriate ‘except’ clause.  This isn’t necessarily the case, and later we’ll see some situations where the exception propagation gets diverted.

How about the try/finally form of SEH?  Well, it’s built on the same underlying notion of a chain of callbacks.  During the first pass (the one where the filters execute, to decide which except block is going to catch), the finally handlers all say EXCEPTION_CONTINUE_SEARCH.  They never actually catch anything.  Then in the second pass, they execute their finally blocks.

**Subsequent additions to SEH**

All of the above – and a lot more – is in Matt’s article.  There are a few things that aren’t in his article because they were added to the model later.

For example, Windows XP introduced the notion of a vectored exception handler.  This allows the application to register for a first crack at an exception, without having to wait for exception handling to propagate down the stack to an embedded handler.  Fortunately, Matt wrote an “Under The Hood” article on this particular topic.  This can be found at http://msdn.microsoft.com/msdnmag/issues/01/09/hood/default.aspx.

Another change to SEH is related to security.  Buffer overruns – whether on the stack or in heap blocks – remain a favorite attack vector for hackers.  A typical buffer overrun attack is to pass a large string as an argument to an API.  If that API expected a shorter string, it might have a local on the stack like “char filename[256];”.  Now if the API is foolish enough to strcpy a malicious hacker’s argument into that buffer, then the hacker can put some fairly arbitrary data onto the stack at addresses higher (further back on the stack) than that ‘filename’ buffer.  If those higher locations are supposed to contain call return addresses, the hacker may be able to get the CPU to transfer execution into the buffer itself.  Oops.  The hacker is injecting arbitrary code and then executing it, potentially inside someone else’s process or under their security credentials.

There’s a new speed bump that an application can use to reduce the likelihood of a successful stack-based buffer overrun attack.  This involves the /GS C++ compiler switch, which uses a cookie check in the function epilog to determine whether a buffer overrun has corrupted the return address before executing a return based on its value.

However, the return address trick is only one way to exploit buffer overruns.  We’ve already seen that SEH records are necessarily built on the stack.  And in fact the OS actually checks to be sure they are within the stack bounds.  Those SEH records contain callback pointers which the OS will invoke if an exception occurs.  So another way to exploit a buffer overrun is to rewrite the callback pointer in an SEH record on the stack.  There’s a new linker switch (/SAFESEH) that can provide its own speed bump against this sort of attack.  Modules built this way declare that all their handlers are embedded in a table in the image; they do not point to arbitrary code sequences sprinkled in the stack or in heap blocks.  During exception processing, the exception callbacks can be validated against this table.

Of course, the first and best line of defense against all these attacks is to never overrun a buffer.  If you are writing in managed code, this is usually pretty easy.  You cannot create a buffer overrun in managed code unless the CLR contains a bug or you perform unsafe operations (e.g. unverifiable MC++ or ‘unsafe’ in C#) or you use high-privilege unsafe APIs like StructureToPtr or the various overloads of Copy in the System.Runtime.InteropServices.Marshal class.

So, not surprisingly and not just for this reason, I recommend writing in managed code.  But if you must write some unmanaged code, you should seriously consider using a String abstraction that eliminates all those by-rote opportunities for error.  And if you must code each strcpy individually, be sure to use strncpy instead!

A final interesting change to the OS SEH model since Matt’s article is due to Win64.  Both IA64 and AMD64 have a model for exception handling that avoids reliance on an explicit handler chain that starts in TLS and is threaded through the stack.  Instead, exception handling relies on the fact that on 64-bit systems we can perfectly unwind a stack.  And this ability is itself due to the fact that these chips are severely constrained on the calling conventions they support.

If you look at X86, there are an unbounded number of calling conventions possible.  Sure, there are a few common well-known conventions like stdcall, cdecl, thiscall and fastcall.  But optimizing compilers can invent custom calling conventions based on inter-procedural analysis.  And developers writing in assembly language can make novel decisions about which registers to preserve vs. scratch, how to use the floating point stack, how to encode structs into registers, whether to back-propagate results by re-using the stack that contained in-bound arguments, etc.  Within the CLR, we have places where we even unbalance the stack by encoding data after a CALL instruction, which is then addressable via the return address.  This is a particularly dangerous game because it upsets the branch prediction code of the CPU and can cause prediction misses on several subsequent RET instructions.  So we are careful to reserve this technique for low frequency call paths.  And we also have some stubs that compute indirect JMPs to out-of-line RET ‘n’ instructions in order to rebalance the stack.

It would be impossible for a stack crawler to successfully unwind these bizarre stacks for exception purposes, without completely simulating arbitrary code execution.  So on X86 the exception mechanism must rely on the existence of a chain of crawlable FS:[0] handlers that is explicitly maintained.

Incidentally, the above distinction between perfect stack crawling on 64-bit systems vs. hopeless stack crawling on X86 systems has deeper repercussions for the CLR than just exception handling.  The CLR needs the ability to crawl all the managed portions of a thread’s stack on all architectures.  This is a requirement for proper enforcement of Code Access Security; for accurate reporting of managed references to the GC; for hijacking return addresses in order to asynchronously take control of threads; and for various other reasons.  On X86, the CLR devotes considerable resources to achieving this.

Anyway, on 64-bit systems the correspondence between an activation record on the stack and the exception record that applies to it is not achieved through an FS:[0] chain.  Instead, unwinding of the stack reveals the code addresses that correspond to a particular activation record.  These instruction pointers of the method are looked up in a table to find out whether there are any __try/__except/__finally clauses that cover these code addresses.  This table also indicates how to proceed with the unwind by describing the actions of the method epilog.

**Managed Exceptions**

Okay, enough about SEH – for now.  Let’s switch to the managed exception model.  This model contains a number of constructs.  Depending on the language you code in, you probably only have access to a subset of these.

**`try {…} finally {…}`**

This is pretty standard.  All managed languages should expose this, and it should be the most common style of exception handling in user code.  Of course, in the case of MC++ the semantics of ‘finally’ is exposed through auto-destructed stack objects rather than through explicit finally clauses.  You should be using ‘finally’ clauses to guarantee consistency of application state far more frequently than you use ‘catch’ clauses.  That’s because catch clauses increase the likelihood that developers will swallow exceptions that should be handled elsewhere, or perhaps should even be left unhandled.  And if catch clauses don’t actually swallow an exception (i.e. they ‘rethrow’), they still create a poor debugging experience as we shall see.

**`try {…} catch (Object o) {…}`**

This is pretty standard, too.  One thing that might surprise some developers is that you can catch any instance that’s of type Object or derived from Object.  However, there is a CLS rule that only subtypes of System.Exception should be thrown.  In fact, C# is so eager for you to only deal with System.Exception that it doesn’t provide any access to the thrown object unless you are catching Exception or one of its subtypes.

When you consider that only Exception and its subtypes have support for stack traces, HRESULT mapping, standard access to exception messages, and good support throughout the frameworks, then it’s pretty clear that you should restrict yourself to throwing and processing exceptions that derive from Exception.

In retrospect, perhaps we should have limited exception support to Exception rather than Object.  Originally, we wanted the CLR to be a useful execution engine for more run-time libraries than just the .NET Frameworks.  We imagined that different languages would execute on the CLR with their own particular run-time libraries.  So we didn’t want to couple the base engine operations too tightly with CLS rules and constructs in the frameworks.  Of course, now we understand that the commonality of the shared framework classes is a huge part of the value proposition of our managed environment.  I suspect we would revisit our original design if we still could.

**`try {…} catch (Object o) if (expression) {…}`**

This is invented syntax, though I’m told it’s roughly what MC++ is considering.  As far as I know, the only two .NET languages that currently support exception filters are VB.NET and – of course – ILASM.  (We never build a managed construct without exposing it via ILDASM and ILASM in a manner that allows these two tools to round-trip between source and binary forms).

VB.NET has sometimes been dismissed as a language that’s exclusively for less sophisticated developers.  But the way this language exposes the advanced feature of exception filters is a great example of why that position is too simplistic.  Of course, it is true that VB has historically done a superb job of providing an approachable toolset and language, which has allowed less sophisticated developers to be highly productive.

Anyway, isn’t this cool:

```
Try
   …try statements…
Catch e As InvalidOperationException When expressionFilter
   …catch statements…
End Try
```

Of course, at the runtime level we cannot separate the test for the exception type expression and the filter expression.  We only support a bare expression.  So the VB compiler turns the above catch into something like this, where $exception_obj is the implicit argument passed to the filter.

```
Catch When (IsInst($exception_obj, InvalidOperationException)
            && expressionFilter)
```

While we’re on the topic of exception handling in VB, have you ever wondered how VB .NET implements its On Error statement?

```
On Error { Goto { <line> | 0 | -1 } | Resume Next }
```

Me neither.  But I think it’s pretty obvious how to implement this sort of thing with an interpreter.  You wait for something to go wrong, and then you consult the active “On Error” setting.  If it tells you to “Resume Next”, you simply scan forwards to the next statement and away you go.

But in an SEH world, it’s a little more complicated.  I tried some simple test cases with the VB 7.1 compiler.  The resulting codegen is based on advancing a _Vb_t_CurrentStatement local variable to indicate the progression of execution through the statements.  A single try/filter/catch covers execution of these statements.  It was interesting to see that the ‘On Error’ command only applies to exceptions that derive from System.Exception.  The filter refuses to process any other exceptions.

So VB is nicely covered.  But what if you did need to use exception filters from C#?  Well, in V1 and V1.1, this would be quite difficult.  But C# has announced a feature for their next release called anonymous methods.  This is a compiler feature that involves no CLR changes.  It allows blocks of code to be mentioned inline via a delegate.  This relieves the developer from the tedium of defining explicit methods and state objects that can be gathered into the delegate and the explicit sharing of this state.  This and other seductive upcoming C# features are described at http://msdn.microsoft.com/library/default.asp?url=/library/en-us/dv_vstechart/html/vbconcprogramminglanguagefuturefeatures.asp.

Using a mechanism like this, someone has pointed out that one could define delegates for try, filter and catch clauses and pass them to a shared chunk of ILASM.  I love the way the C# compiler uses type inferencing to automatically deduce the delegate types.  And it manufactures a state object to ensure that the locals and arguments of DoTryCatch are available to the “try statements”, “filter expression” and “catch statements”, almost as if everything was scoped in a single method body.  (I say “almost” because any locals or arguments that are of byref, argiterator or typedbyref types cannot be disassociated from a stack without breaking safety.  So these cases are disallowed).

I’m guessing that access to filters from C# could look something like this:

```
public void delegate __Try();
public Int32 delegate __Filter();
public void delegate __Catch();

// this reusable helper would be defined in ILASM or VB.NET:
void DoTryCatch(__Try t, __Filter f, __Catch c)

// And C# could then use it as follows:
void m(…arguments…)
{
   …locals…
   DoTryCatch(
      { …try statements…},
      { return filter_expression; },
      { …catch statements…}
   );
}
```

You may notice that I cheated a little bit.  I didn’t provide a way for the ‘catch’ clause to mention the exception type that it is catching.  Of course, this could be expressed as part of the filter, but that’s not really playing fair.  I suspect the solution is to make DoTryCatch a generic method that has an unbound Type parameter.  Then DoTryCatch<T> could be instantiated for a particular type.  However, I haven’t actually tried this so I hate to pretend that it would work.  I am way behind on understanding what we can and cannot do with generics in our next release, how to express this in ILASM, and how it actually works under the covers.  Any blog on that topic is years away.

While we are on the subject of interesting C# codegen, that same document on upcoming features also discusses iterators.  These allow you to use the ‘yield’ statement to convert the normal pull model of defining iteration into a convenient push model.  You can see the same ‘yield’ notion in Ruby.  And I’m told that both languages have borrowed this from CLU, which pioneered the feature about the time that I was born.

When you get your hands on an updated C# compiler that supports this handy construct, be sure to ILDASM your program and see how it’s achieved.  It’s a great example of what a compiler can do to make life easier for a developer, so long as we’re willing to burn a few more cycles compared to a more prosaic loop construct.  In today’s world, this is almost always a sensible trade-off.

Okay, that last part has nothing to do with exceptions, does it?  Let’s get back to the managed exception model.

**`try {…} fault {…}`**

Have you ever written code like this, to restrict execution of your finally clause to just the exceptional cases?

```
bool exceptional = true;
try {
   …body of try…
   exceptional = false;
} finally {
   if (exceptional) {…}
}
```

Or how about a catch with a rethrow, as an alternate technique for achieving finally behavior for just the exceptional cases:

```
try {
   …
} catch {
   …
   rethrow;
}
```

In each case, you are accommodating for the fact that your language doesn’t expose fault blocks.  In fact, I think the only language that exposes these is ILASM.  A fault block is simply a finally clause that only executes in the exceptional case.  It never executes in the non-exceptional case.

Incidentally, the first alternative is preferable to the second.  The second approach terminates the first pass of exception handling.  This is a fundamentally different semantics, which has a substantial impact on debugging and other operations.  Let’s look at rethrow in more detail, to see why this is the case.

**Rethrow, restartable exceptions, debugging**

Gee, my language has rethrow, but no filter.  Why can’t I just treat the following constructs as equivalent?

```
try {…} filter (expression) catch (Exception e) {…}
try {…} catch (Exception e) { if (!expression) rethrow; …}
```

In fact, ‘rethrow’ tries hard to create the illusion that the initial exception handling is still in progress.  It uses the same exception object.  And it augments the stack trace associated with that exception object, so that it includes the portion of stack from the rethrow to the eventual catch.

Hmm, I guess I should have already mentioned that the stack trace of an Exception is intentionally restricted to the segment of stack from the throw to the catch.  We do this for performance reasons, since part of the cost of an exception is linear with the depth of the stack that we capture.  I’ll talk about the implications of exception performance later.  Of course, you can use the System.Diagnostics.StackTrace class to gather the rest of the stack from the point of the catch, and then manually merge it into the stack trace from the Exception object.  But this is a little clumsy and we have sometimes been asked to provide a helper to make this more convenient and less brittle to changes in the formatting of stack traces.

Incidentally, when you are playing around with stack traces (whether they are associated with exceptions, debugging, or explicit use of the StackTrace class), you will always find JIT inlining getting in your way.  You can try to defeat the JIT inliner through use of indirected calls like function pointers, virtual methods, interface calls and delegates.  Or you can make the called method “interesting” enough that the JIT decides it would be unproductive or too difficult to inline.  All these techniques are flawed, and all of them will fail over time.  The correct way to control inlining is to use the MethodImpl(MethodImplOptions.NoInlining) pseudo-custom attribute from the System.Runtime.CompilerServices namespace.

One way that a rethrow differs from a filter is with respect to resumable or restartable exceptions.  We’ve already seen how SEH allows an exception filter to return EXCEPTION_CONTINUE_EXECUTION.  This causes the faulting instruction to be restarted.  Obviously it’s unproductive to do this unless the filter has first taken care of the faulting situation somehow.  It could do this by changing the register state in the exception context so that a different value is dereferenced, or so that execution resumes at a different instruction.  Or it could have modified the environment the program is running in, as with the VirtualProtect cases that I mentioned earlier.

In V1 and V1.1, the managed exception model does not support restartable exceptions.  In fact, I think that we set EXCEPTION_NONCONTINUABLE on some (but perhaps not all) of our exceptions to indicate this.  There are several reasons why we don’t support restartable exceptions:

* In order to repair a faulting situation, the exception handler needs intimate knowledge about the execution environment.  In managed code, we’ve gone to great lengths to hide these details.  For example, there is no architecture-neutral mapping from the IL expression of stack-based execution to the register set of the underlying CPU.
* Restartability is often desired for asynchronous exceptions.  By ‘asynchronous’ I mean that the exception is not initiated by an explicit call to ‘throw’ in the code.  Rather, it results from a memory fault or an injected failure like Abort that can happen on any instruction.  Propagating a managed exception, where this involves execution of a managed filter, necessarily involves the potential for a GC.  A JIT has some discretion over the GC-safe points that it chooses to support in a method.  Certainly the JIT must gather GC information to report roots accurately at all call-sites.  But the JIT normally isn’t required to maintain GC info for every instruction.  If any instruction might fault, and if any such fault could be resumed, then the JIT would need GC info for all instructions in all methods.  This would be expensive.  Of course, ‘mov eax, ecx’ cannot fault due to memory access issues.  But a surprising number of instructions are subject to fault if you consider all of memory – including the stack – to be unmapped.  And even ‘mov eax, ecx’ can fault due to a Thread.Abort.

If you were paying attention to that last bullet, you might be wondering how asynchronous exceptions could avoid GC corruption even without resumption.  After all, the managed filter will still execute and we know that the JIT doesn’t have complete GC information for the faulting instruction.

Our current solution to this on X86 is rather ad hoc, but it does work.  First, we constrain the JIT to never flow the contents of the scratch registers between a ‘try’ clause and any of the exception clauses (‘filter’, ‘finally’, ‘fault’ and ‘catch’).  The scratch registers in this case are EAX, ECX, EDX and sometimes EBP.  Our JIT compiler decides, method-by-method, whether to use EBP as a stack-frame register or a scratch register.  Of course, EBP isn’t really a scratch register since callees will preserve it for us, but you can see where I’m going.

Now when an asynchronous exception occurs, we can discard the state of all the scratch registers.  In the case of EAX, ECX & EDX, we can unconditionally zero them in the register context that is flowed via exception propagation.  In the case of EBP, we only zero it if we aren’t using EBP as a frame register.  When we execute a managed handler, we can now report GC roots based on the GC information that’s associated with the handler’s instruction pointer.

The downside to this approach, other than its ad hoc nature, is that it constrains the codegen of any method that contains exception handlers.  At some point we may have to model asynchronous exceptions more accurately, or expand the GC information spewed by the JIT compiler, or a combination, so that we can enable better code generation in the presence of exceptions.

We’ve already seen how VB.NET can use a filter and explicit logic flow from a catch clause to create the illusion of restartable exceptions to support ‘On Error Resume Next’.  But this should not be confused with true restartability.

Before we leave the topic of rethrow, we should briefly consider the InnerException property of System.Exception.  This allows one exception to be wrapped up in the state of another exception.  A couple of important places where we take advantage of this are reflection and class construction.

When you perform late-bound invocation via reflection (e.g. Type.InvokeMember or MethodInfo.Invoke), exceptions can occur in two places:

1. The reflection infrastructure may decide that it cannot satisfy your request, perhaps because you passed the wrong number of arguments, or the member lookup failed, or you are invoking on someone else’s private members.  That last one sounds vaguely dirty.

2. The late-bound invocation might work perfectly, but the target method you called may throw an exception back at you.  Reflection must faithfully give you that exception as the result of the call.  Returning it as an outbound argument, rather than throwing it at you, would be dangerous.  We would lose one of the wonderful properties of exceptions, which is that they are hard to ignore.  Error codes are constantly being swallowed or otherwise ignored, leading to fragile execution.

The problem is that these two sources of exceptions are ambiguous.  There must be some way to tell whether the invocation attempt failed or whether the target of the invocation failed.   Reflection disambiguates these cases by using an instance of System.Reflection.TargetInvocationException for the case where the invoked method threw an exception.  The InnerException property of this instance is the exception that was thrown by the invoked method.  If you get any exceptions from a late-bound invocation other than TargetInvocationException, those other exceptions indicate problems with the late-bound dispatch attempt itself.

Something similar happens with TypeInitializationException.  If a class constructor (.cctor) method fails, we capture that exception as the InnerException of a TypeInitializationException.  Subsequent attempts to use that class in this AppDomain from this or other threads will have that same TypeInitializationException instance thrown at them.

So what’s the difference between the following three constructs, where the overloaded constructor for MyExcep is placing its argument into InnerException:

```
try {…} catch (Exception e) { if (expr) rethrow; …}
try {…} catch (Exception e) { if (expr) throw new MyExcep(); …}
try {…} catch (Exception e) { if (expr) throw new MyExcep(e); …}
```

Well, the 2nd form is losing information.  The original exception has been lost.  It’s hard to recommend that approach.

Between the 1st and 3rd forms, I suppose it depends on whether the intermediary can add important information by wrapping the original exception in a MyExcep instance.  Even if you are adding value with MyExcep, it’s still important to preserve the original exception information in the InnerException so that sophisticated programs and developers can determine the complete cause of the error.

Probably the biggest impact from terminating the first pass of exception handling early, as with the examples above, is on debugging.  Have you ever attached a debugger to a process that has failed with an unhandled exception?  When everything goes perfectly, the debugger pops up sitting in the context of the RaiseException or trap condition.

That’s so much better than attaching the debugger and ending up on a ‘rethrow’ statement.  What you really care about is the state of the process when the initial exception was thrown.  But the first pass has terminated and the original state of the world may have been lost.  It’s clear why this happens, based on the two pass nature of exception handling.

Actually, the determination of whether or not the original state of the world has been lost or merely obscured is rather subtle.  Certainly the current instruction pointer is sitting in the rethrow rather than on the original fault.  But remember how filter and finally clauses are executed with an EBP that puts the containing method’s locals in scope… and an ESP that still contains the original faulting method?  It turns out that the catching handler has some discretion on whether to pop ESP before executing the catch clause or instead to delay the pop until the catch clause is complete.  The managed handler currently pops the stack before calling the catch clause, so the original state of the exception is truly lost.  I believe the unmanaged C++ handler delays the pop until the catch completes, so recovering the state of the world for the original exception is tricky but possible.

Regardless, every time you catch and rethrow, you inflict this bitter disappointment on everyone who debugs through your code.  Unfortunately, there are a number of places in managed code where this disappointment is unavoidable.

The most unfortunate place is at AppDomain boundaries.  I’ve already explained at http://cbrumme.dev/appdomains why the Isolation requirement of AppDomains forces us to marshal most exceptions across the boundary.  And we’ve just discussed how reflection and class construction terminate the first pass by wrapping exceptions as the InnerException of an outer exception.

One alternative is to trap on all first-chance exceptions.  That’s because debuggers can have first crack at exceptions before the vectored exception handler even sees the fault.  This certainly gives you the ability to debug each exception in the context in which it was thrown.  But you are likely to see a lot of exceptions in the debugger this way!

In fact, throughout V1 of the runtime, the ASP.NET team ran all their stress suites with a debugger attached and configured to trap on first-chance Access Violations (“sxe av”).  Normally an AV in managed code is converted to a NullReferenceException and then handled like any other managed exception.  But ASP.NET’s settings caused stress to trap in the debugger for any such AV.  So their team enforced a rule that all their suites (including all dependencies throughout FX) must avoid such faults.

It’s an approach that worked for them, but it’s hard to see it working more broadly.

Instead, over time we need to add new hooks to our debuggers so they can trap on just the exceptions you care about.  This might involve trapping exceptions that are escaping your code or are being propagated into your code (for some definition of ‘your code’).  Or it might involve trapping exceptions that escape an AppDomain or that are propagated into an AppDomain.

The above text has described a pretty complete managed exception model.  But there’s one feature that’s conspicuously absent.  There’s no way for an API to document the legal set of exceptions that can escape from it.  Some languages, like C++, support this feature.  Other languages, like Java, mandate it.  Of course, you could attach Custom Attributes to your methods to indicate the anticipated exceptions, but the CLR would not enforce this.  It would be an opt-in discipline that would be of dubious value without global buy-in and guaranteed enforcement.

This is another of those religious language debates.  I don’t want to rehash all the reasons for and against documenting thrown exceptions.  I personally don’t believe the discipline is worth it, but I don’t expect to change the minds of any proponents.  It doesn’t matter.

What does matter is that disciplines like this must be applied universally to have any value.  So we either need to dictate that everyone follow the discipline or we must so weaken it that it is worthless even for proponents of it.  And since one of our goals is high productivity, we aren’t going to inflict a discipline on people who don’t believe in it – particularly when that discipline is of debatable value.  (It is debatable in the literal sense, since there are many people on both sides of the argument).

To me, this is rather like ‘const’ in C++.  People often ask why we haven’t bought into this notion and applied it broadly throughout the managed programming model and frameworks.  Once again, ‘const’ is a religious issue.  Some developers are fierce proponents of it and others find that the modest benefit doesn’t justify the enormous burden.  And, once again, it must be applied broadly to have value.

Now in C++ it’s possible to ‘const-ify’ the low level runtime library and services, and then allow client code to opt-in or not.  And when the client code runs into places where it must lose ‘const’ in order to call some non-const-ified code, it can simply remove ‘const’ via a dirty cast.  We have all done this trick, and it is one reason that I’m not particularly in favor of ‘const’ either.

But in a managed world, ‘const’ would only have value if it were enforced by the CLR.  That means the verifier would prevent you from losing ‘const’ unless you explicitly broke type safety and were trusted by the security system to do so.  Until more than 80% of developers are clamoring for an enforced ‘const’ model throughout the managed environment, you aren’t going to see us added it.

**Foray into C++ Exceptions**

C++ exposes its own exception model, which is distinct from the __try / __except / __finally exposure of SEH.  This is done through auto-destruction of stack-allocated objects and through the ‘try’ and ‘catch’ keywords.  Note that there are no double-underbars and there is no support for filters other than through matching of exception types.  Of course, under the covers it’s still SEH.  So there’s still an FS:[0] handler (on X86).  But the C++ compiler optimizes this by only emitting a single SEH handler per method regardless of how many try/catch/finally clauses you use.  The compiler emits a table to indicate to a common service in the C-runtime library where the various try, catch and finally clauses can be found in the method body.

Of course, one of the biggest differences between SEH and the C++ exception model is that C++ allows you to throw and catch objects of types defined in your application.  SEH only lets you throw 32-bit exception codes.  You can use _set_se_translator to map SEH codes into the appropriate C++ classes in your application.

A large part of the C++ exception model is implicit.  Rather than use explicit try / finally / catch clauses, this language encourages use of auto-destructed local variables.  Whether the method unwinds via a non-exceptional return statement or an exception being thrown, that local object will auto-destruct.

This is basically a ‘finally’ clause that’s been wrapped up in a more useful language construct.  Auto-destruction occurs during the second pass of SEH, as you would expect.

Have you noticed that the C++ exception you throw is often a stack-allocated local?  And that if you explicitly catch it, this catch is also with a stack-allocated object?  Did you ever wake up at night in a cold sweat, wondering whether a C++ in-flight exception resides on a piece of stack that’s already been popped?  Of course not.

In fact, we’ve now seen enough of SEH to understand how the exception always remains in a section of the stack above ESP (i.e. within the bounds of the stack).  Prior to the throw, the exception is stack-allocated within the active frame.  During the first pass of SEH, nothing gets popped.  When the filters execute, they are pushed deeper on the stack than the throwing frame.

When a frame declares it will catch the exception, the second pass starts.  Even here, the stack doesn’t unwind.  Then, before resetting the stack pointer, the C++ handler can copy-construct the original exception from the piece of stack that will be popped into the activation frame that will be uncovered.

If you are an expert in unmanaged C++ exceptions, you will probably be interested to learn of the differences between managed C++ exceptions and unmanaged C++ exceptions.  There’s a good write-up of these differences at http://msdn.microsoft.com/library/default.asp?url=/library/en-us/vcmex/html/vccondifferencesinexceptionhandlingbehaviorundermanagedexceptionsforc.asp.

**A Single Managed Handler**

We’ve already seen how the C++ compiler can emit one SEH handler per method and reuse it for all the exception blocks in that method.  The handler can do this by consulting a side table that indicates how the various clauses map to instruction sequences within that method.

In the managed environment, we can take this even further.  We maintain a boundary between managed and unmanaged code for many reasons, like synchronization with the garbage collector, to enable stack crawling through managed code, and to marshal arguments properly.  We have modified this boundary to erect a single SEH handler at every unmanaged -> managed call in.  For the most part, we must do this without compiler support since many of our transitions occur through dynamically generated machine code.

The cost of modifying the SEH chain during calls into managed code is quickly amortized as we call freely between managed methods.  So the immediate cost of pushing FS:[0] handlers on method entry is negligible for managed code.  But there is still an impact on the quality of the generated code.  We saw part of this impact in the discussion of register usage across exception clauses to remain GC-safe.

Of course, the biggest cost of exceptions is when you actually throw one.  I’ll return to this near the end of the blog.

**Flow Control**

Here’s an interesting scenario that came up recently.

Let’s say we drive the first pass of exception propagation all the way to the end of the handler chain and we reach the unhandled exception backstop.  That backstop will probably pop a dialog in the first pass, saying that the application has suffered an unhandled exception.  Depending on how the system is configured, the dialog may allow us to terminate the process or debug it.  Let’s say we choose Terminate.

Now the 2nd pass begins.  During the 2nd pass, all our finally clauses can execute.

What if one of those 2nd pass ‘finally’ clauses throws a new exception?  We’re going to start a new exception propagation from this location – with a new Exception instance.  When we drive this new Exception up the chain, we may actually find a handler that will swallow the second exception.

If this is the case, the process won’t terminate due to that first exception.  This is despite the fact that SEH told the user we had an unhandled exception, and the user told us to terminate the process.

This is surprising, to say the least.  And this behavior is possible, regardless of whether managed or unmanaged exceptions are involved.  The mechanism for SEH is well-defined and the exception model operates within those rules.  An application should avoid certain (ab)uses of this mechanism, to avoid confusion.

Indeed, we have prohibited some of those questionable uses in managed code.

In unmanaged, you should never return from a finally.  In an exceptional execution of a finally, a return has the effect of terminating the exception processing.  The catch handler never sees its 2nd pass and the exception is effectively swallowed.  Conversely, in a non-exceptional execution of a finally, a return has the effect of replacing the method’s return value with the return value from the finally.  This is likely to cause developer confusion.

So in managed code we’ve made it impossible for you to return from a finally clause.  The full rules for flow control involving managed exception clauses should be found at Section 12.4.2.8 of ECMA Partition I (http://msdn.microsoft.com/net/ecma/).

However, it is possible to throw from a managed finally clause.  (In general, it’s very hard to confidently identify regions of managed code where exceptions cannot be thrown).  And this can have the effect of replacing the exception that was in flight with a new 1st and 2nd pass sweep, as described above.  This is the ExceptionCollidedUnwind situation that is mentioned in the EXCEPTION_DISPOSITION enumeration.

The C++ language takes a different approach to exceptions thrown from the 2nd pass.  We’ve already seen that C++ autodestructors execute during the 2nd pass of exception handling.  If you’ve ever thrown an exception from the destructor, when that destructor is executed as part of an exception unwind, then you have already learned a painful lesson.  The C++ behavior for this situation is to terminate the process via a termination handler.

In unmanaged C++, this means that developers must follow great discipline in the implementation of their destructors.  Since eventually those destructors might run in the context of exception backout, those destructors should never allow an exception to escape them.  That’s painful, but presumably achievable.

In managed C++, I’ve already mentioned that it’s very hard to identify regions where exceptions cannot occur.  The ability to prevent (asynchronous and resource) exceptions over limited ranges of code is something we would like to enable at some point in the future, but it just isn’t practical in V1 and V1.1.  It’s way too easy for an out-of-memory or type-load or class-initialization or thread-abort or appdomain-unload or similar exception to intrude.

Finally, it’s possible for exceptions to be thrown during execution of a filter.  When this happens in an OS SEH context, it results in the ExceptionNestedException situation that is mentioned in the EXCEPTION_DISPOSITION enumeration.  The managed exception model took a different approach here.  We’ve already seen that an MSVC filter clause has three legal returns values (resume execution, continue search, and execute handler).  If a managed filter throws an exception, we contain that exception and consider the filter to have replied “No, I don’t want to handle this one.  Continue searching for a handler”.

This is a reasonable interpretation in all cases, but it falls out particularly well for stack overflow.  With the historical OS support for stack overflow, it’s very hard to reliably execute backout code.  As I’ve mentioned in other blogs, you may only have one 4K page of stack available for this purpose.  If you blow that page, the process is terminated.  It’s very hard to execute managed filters reliably within such a limited region.  So a reasonable approach is to consider the filters to have themselves thrown a StackOverflowException and for us to interpret this as “No, I don’t want to handle this one.”

In a future version, we would like to provide a more defensible and useful mechanism for handling stack overflow from managed code.

**Error Handling without Exceptions**

So we’ve seen how SEH and C++ and managed exceptions all interoperate.  But not all error handling is based on exceptions.  When we consider Windows, there are two other error handling systems that the CLR can interoperate with.  These are the Get/SetLastError mechanism used by the OS and the HRESULT / IErrorInfo mechanism used by COM.

Let’s look at the GetLastError mechanism first, because it’s relatively simple.  A number of OS APIs indicate failure by returning a sentinel value.  Usually this sentinel value is -1 or 0 or 1, but the details vary depending on the API.  This sentinel value indicates that the client can call GetLastError() to recover a more detailed OS status code.  Unfortunately, it’s sometimes hard to know which APIs participate in the GetLastError protocol.  Theoretically this information is always documented in MSDN and is consistent from one version of the OS to the next – including between the NT and Win95-based OSes.

The real issue occurs when you PInvoke to one of these methods.  The OS API latches any failure codes with SetLastError.  Now on the return path of the PInvoke, we may be calling various OS services and managed services to marshal the outbound arguments.  We may be synchronizing with a pending GC, which could involve a blocking operation like WaitForSingleObject.  Somewhere in here, we may call another OS API that itself latches an error code (or the absence of an error code) through its own call to SetLastError.

So by the time we return to some managed code that can generate up a new PInvoke stub to call GetLastError, you can be sure that the original error code is long gone.  The solution is to tag your PInvoke declaration to indicate that it should participate in the GetLastError protocol.  This tells the PInvoke call to capture the error as part of the return path, before any other OS calls on this thread have an opportunity to erase it or replace it.

This protocol works well for PInvokes.  Unfortunately, we do not have a way to tag IJW VTFixup stubs in the same way.  So when you make managed -> unmanaged calls via MC++ IJW, there isn’t a convenient and reliable way to recover a detailed OS status code on the return path.  Obviously this is something we would like to address in some future version, though without blindly inflicting the cost of a GetLastError on all managed -> unmanaged transitions through IJW.

**COM Error Handling**

To understand how the CLR interoperates with COM HRESULTs, we must first review how PreserveSig is used to modify the behavior of PInvoke and COM Interop.

Normally, COM signatures return an HRESULT error code.  If the method needs to communicate some other result, this is typically expressed with an [out, retval] outbound argument.  Of course, there are exceptions to this pattern.  For example, IUnknown::AddRef and Release both return a count of the outstanding references, rather than an HRESULT.  More importantly, HRESULTs can be used to communicate success codes as well as error codes.  The two most typical success codes are S_OK and S_FALSE, though any HRESULT with the high bit reset is considered a success code.

COM Interop normally transforms the unmanaged signature to create a managed signature where the [out, retval] argument becomes the managed return value.  If there is no [out, retval], then the return type of the managed method is ‘void’.  Then the COM Interop layer maps between failure HRESULTs and managed exceptions.  Here’s a simple example:

* COM:  HRESULT GetValue([out, retval] IUnknown **ppRet)`
* CLR:  IUnknown GetValue()

However, the return value might be a DWORD-sized integer that should not be interpreted as an HRESULT.  Or it might be an HRESULT – but one which must sometimes distinguish between different success codes.  In these cases, PreserveSig can be specified on the signature and it will be preserved on the managed side as the traditional COM signature.

Of course, the same can happen with PInvoke signatures.  Normally a DLL export like Ole32.dll’s CoGetMalloc would have its signature faithfully preserved.  Presumably the transformation would be something like this:

* DLL:  HRESULT CoGetMalloc(DWORD c, [out, retval] IMalloc **ppRet)
* CLR:  DWORD   CoGetMalloc(DWORD c, ref IMalloc ppRet)

If OLE32 returns some sort of failure HRESULT from this call, it will be returned to the managed caller.  If instead the application would prefer to get this error case automatically converted to a managed Exception, it can use PreserveSig to indicate this.

Huh?  In the COM case PreserveSig means “give me the unconverted HRESULT signature”, but in the PInvoke case PreserveSig means “convert my HRESULTs into exceptions.”  Why would we use the same flag to indicate exactly opposite semantics for these two interop layers?  The reasons are, ahem, historical.  The best way to think of PreserveSig is “give me the unusual transformation of my signature, as opposed to what is typical for the kind of interop I am doing.”

So now we know how to obtain mappings between HRESULTs and managed exceptions for the typical COM Interop case (no PreserveSig) and the atypical PInvoke case (PreserveSig).  But what are the details of that mapping?

The exception subsystem in the CLR has mappings between COM errors, OS errors, and managed exception types.

Of course, sometimes we have a situation which doesn’t have a precise mapping.  In the case of an HRESULT that isn’t associated with a specific managed Exception class, we convert it to an instance of COMException.  In the case of an OS status code that isn’t associated with a specific managed Exception class, we convert it to an instance of SEHException.

Even for cases where we have a correspondence between a managed and unmanaged representation, the mapping won’t necessarily roundtrip.  For instance, an AV in unmanaged code results in an SEH exception of code 0xC0000005.  If this is driven through managed code, it will be mapped to the corresponding NullReferenceException class.  If the propagation of this exception continues through managed code and further up the stack to an unmanaged SEH handler, the unmanaged code will see the original exception code of 0xC0000005.  So, when propagating through that sequence of handlers, we see a perfect roundtrip.

But let’s change the scenario slightly, so that the original AccessViolation occurs in managed code.  Now we have a NullReferenceException that is being propagated out to an unmanaged SEH handler further back on the stack.  But this time the NullReferenceException will be mapped to an SEH exception code of 0xE0434F4D.  This is the managed exception code used for all managed exceptions.

Have you ever wondered where these exception codes come from?  Well 0xE0434F4D is 0xE0+“COM”.  Originally the CLR was called COM+ 2.0.  When we changed the project name, we neglected to change the exception code.  The unmanaged C++ exceptions use 0xE06D7363, which is 0xE0+“msc”.  You might also see 0xE0524F54 for 0xE0+“ROT” on Rotor builds.

The current mapping between OS status codes and managed exception types is quite limited.  It contains standard transformations like:

```
STATUS_FLOAT_INEXACT_RESULT
STATUS_FLOAT_INVALID_OPERATION
STATUS_FLOAT_STACK_CHECK
STATUS_FLOAT_UNDERFLOW         => ArithmeticException
STATUS_FLOAT_OVERFLOW
STATUS_INTEGER_OVERFLOW        => OverflowException
STATUS_FLOAT_DIVIDE_BY_ZERO
STATUS_INTEGER_DIVIDE_BY_ZERO  => DivideByZeroException
STATUS_FLOAT_DENORMAL_OPERAND  => FormatException
STATUS_ACCESS_VIOLATION        => NullReferenceException
STATUS_ARRAY_BOUNDS_EXCEEDED   => IndexOutOfRangeException
STATUS_NO_MEMORY               => OutOfMemoryException
STATUS_STACK_OVERFLOW          => StackOverflowException
```

The HRESULT mappings are far more extensive.  They include standard mappings to the well-known HRESULT values like:

```
E_POINTER                      => ArgumentNullException
```

And they include mappings to CLR-defined HRESULTs in the 0x8013???? range that you’ve doubtless witnessed during your development and debugging.  The managed platform has its own facility code for reserving a range of HRESULTs for our exclusive use.

```
COR_E_ENTRYPOINTNOTFOUND       => EntryPointNotFoundException
```

And our mappings include a gathering of similar HRESULTs to a single managed exception.  Here’s a particularly extensive gathering of 26 different HRESULTs to the FileLoadException class:

```
FUSION_E_REF_DEF_MISMATCH
FUSION_E_INVALID_PRIVATE_ASM_LOCATION
COR_E_ASSEMBLYEXPECTED
FUSION_E_SIGNATURE_CHECK_FAILED
FUSION_E_ASM_MODULE_MISSING
FUSION_E_INVALID_NAME
FUSION_E_PRIVATE_ASM_DISALLOWED
COR_E_MODULE_HASH_CHECK_FAILED
COR_E_FILELOAD
SECURITY_E_INCOMPATIBLE_SHARE
SECURITY_E_INCOMPATIBLE_EVIDENCE
SECURITY_E_UNVERIFIABLE
COR_E_FIXUPSINEXE
HRESULT_FROM_WIN32(ERROR_TOO_MANY_OPEN_FILES)
HRESULT_FROM_WIN32(ERROR_SHARING_VIOLATION)
HRESULT_FROM_WIN32(ERROR_LOCK_VIOLATION)
HRESULT_FROM_WIN32(ERROR_OPEN_FAILED)
HRESULT_FROM_WIN32(ERROR_DISK_CORRUPT)
HRESULT_FROM_WIN32(ERROR_UNRECOGNIZED_VOLUME)
HRESULT_FROM_WIN32(ERROR_FILE_INVALID)
HRESULT_FROM_WIN32(ERROR_DLL_INIT_FAILED)
HRESULT_FROM_WIN32(ERROR_FILE_CORRUPT)
FUSION_E_CODE_DOWNLOAD_DISABLED
CORSEC_E_MISSING_STRONGNAME
INIT_E_DOWNLOAD_FAILURE
MSEE_E_ASSEMBLYLOADINPROGRESS    => FileLoadException
```

There are some more observations we can make about the COM error handling approach.  First, it should be obvious that the 32-bits of an HRESULT cannot uniquely define an arbitrary set of user-extensible error conditions.  COM deals with this, in part, by including the interface that returns an HRESULT in the decision of how to interpret these 32-bits.  This means that 0xE3021051 returned from IMyInterface is not the same error code as 0xE3201051 returned from IYourInterface.  Unfortunately, it also means that each interface must be rigorous about the bit patterns it returns.  Specifically, it would be very bad if the implementation of IMyInterface::m() happens to delegate to IYourInterface::n() and blindly return ‘n’s HRESULTs.  Any HRESULTs returned from ‘n’ must somehow be mapped to the bit patterns that are legal to return from IMyInterface::m().  If ‘n’ returns a bit pattern that IMyInterface::m() cannot map, then ‘m’ is obligated to convert the HRESULT to E_UNEXPECTED and return that.

In other words, the uniqueness constraint for HRESULTs forces a painful discipline on all COM implementations that return HRESULTs.  And part of this discipline is to lose error information by mapping meaningful HRESULTs into E_UNEXPECTED if the context for interpreting those HRESULTs is being lost.  (There is a well-defined set of system HRESULTs which are implicitly returnable from any interface.  The bit pattern for E_UNEXPECTED is necessarily part of this set.  The CLR facility code allows us to live in this privileged world with our own codes).

The fact that most COM developers are unaware of this painful discipline and don’t follow it, just adds to the level of pain here.

Fortunately, COM supplements the limited expressibility and uniqueness of HRESULTs by using a second mechanism: IErrorInfo.  And the COM Interop layer uses this supplementary mechanism when mapping to and from managed exception objects.  In fact, System.Exception implements the IErrorInfo interface.  When a managed exception is thrown to a COM client, the IErrorInfo of the Exception instance is available for the COM client to query.

Adam Nathan’s excellent book “.NET and COM – The Complete Interoperability Guide” describes how the IErrorInfo state is filled in from a managed exception in Chapter 16.

There’s one more detail of COM Interop HRESULT mapping that warrants discussion.  It’s good practice for all COM methods to return an HRESULT.  But there are several famous violations of this rule, including IUnknown::AddRef and Release.  More importantly, every developer can choose whether to follow this best practice.  Some choose not to.  And there are some typical cases, like event sinks, where we often see methods returning ‘void’ or ‘bool’.

This presents the COM Interop error mapping layer with a problem.  If an exception occurs inside a managed implementation of a method with one of these signatures, it’s hard to convey the error information back to the COM caller.  There are several choices available to that layer – none of them good:

1. Allow the managed exception to travel back through the COM caller, using the underlying SEH mechanism.  This would work perfectly, but is strictly illegal.  Well-behaved COM servers do not propagate exceptions out to their COM clients.

2. Swallow the managed exception.  Propagate a return value with ‘0’ out to the COM client.  This 0 value might get interpreted as a returned Boolean, integer, pUnk or other data type.  In the case of a ‘void’ signature, it will simply be ignored.

3. Convert the exception object into an HRESULT value.  Propagate that HRESULT out as the return value to the COM client.  In the ‘void’ case, this will again be ignored.  In the pUnk case, it will likely be dereferenced and subsequently cause an AccessViolation.  (Failure HRESULTs have the high bit set.  On Win32 the high 2 GB of address space are reserved for the kernel and are unavailable unless you run a /LARGEADDRESSAWARE process on a suitably booted system.  On Win64, the low couple of GB of address are reserved and unavailable to detect this sort of mistake).

As you can see, all of these solutions are broken.  Unfortunately, the most broken of the three is the last one… and that’s the one we currently follow.  I suspect we will change our behavior here at some point.  Until then, we rely on the fact that AddRef & Release are specially handled and that the other cases are rare and are typically ‘void’ or ‘bool’ returns.

**Performance and Trends**

Exceptions vs. error codes has always been a controversial topic.  For the last 15 years, every team has argued whether their codebase should throw exceptions or return error codes.  Hopefully nobody argues whether their team should mix both styles.  That’s never desirable, though it often takes major surgery to migrate to a consistent plan.

With any religious controversy, there are many arguments on either side.  Some of them are related to:

* A philosophy of what errors mean and whether they should be expressed out-of-band with the method contract.
* Performance.  Exceptions have a direct cost when you actually throw and catch an exception.  They may also have an indirect cost associated with pushing handlers on method entry.  And they can often have an insidious cost by restricting codegen opportunities.
* It’s relatively easy to forget to check for a returned error code.  It’s much harder to inadvertently swallow an exception without handling it (though we still find developers doing so!)
* Exceptions tend to capture far more information about the cause and location of an error, though one could envision an error code system that’s equally powerful.  (IErrorInfo anybody?)
So what’s the right answer here?

Well if you are building the kernel of an operating system, you should probably use error codes.  You are a programming God who rarely makes mistakes, so it’s less likely that you will forget to check your return codes.  And there are sound bootstrapping and performance reasons for avoiding exceptions within the kernel.  In fact, some of the OS folks here think that SEH should be reserved for terrible “take down the process” situations.  That may have been the original design point.  But SEH is such a flexible system, and it is so entrenched as the basis for unmanaged C++ exceptions and managed exceptions, that it is no longer reasonable to restrict the mechanism to these critical failures.

So, if you are not a programming God like those OS developers, you should consider using exceptions for your application errors.  They are more powerful, more expressive, and less prone to abuse than error codes.  They are one of the fundamental ways that we make managed programming more productive and less error prone.  In fact, the CLR internally uses exceptions even in the unmanaged portions of the engine.  However, there is a serious long term performance problem with exceptions and this must be factored into your decision.

Consider some of the things that happen when you throw an exception:

* Grab a stack trace by interpreting metadata emitted by the compiler to guide our stack unwind.
* Run through a chain of handlers up the stack, calling each handler twice. 
* Compensate for mismatches between SEH, C++ and managed exceptions.
* Allocate a managed Exception instance and run its constructor.  Most likely, this involves looking up resources for the various error messages.
* Probably take a trip through the OS kernel.  Often take a hardware exception.
* Notify any attached debuggers, profilers, vectored exception handlers and other interested parties.

This is light years away from returning a -1 from your function call.  Exceptions are inherently non-local, and if there’s an obvious and enduring trend for today’s architectures, it’s that you must remain local for good performance.

Relative to straight-line local execution, exception performance will keep getting worse.  Sure, we might dig into our current behavior and speed it up a little.  But the trend will relentlessly make exceptions perform worse.

How do I reconcile the trend to worse performance with our recommendation that managed code should use exceptions to communicate errors?  By ensuring that error cases are exceedingly rare.  We used to say that exceptions should be used for exceptional cases, but folks pushed back on that as tautological.

If your API fails in 10% of all calls, you better not use an exception.  Instead, change the API so that it communicates its success or failure as part of the API (e.g. ‘bool TryParse(String s)’).  Even if the API fails 1% of calls, this may be too high a rate for a service that’s heavily used in a server.  If 1% of calls fail and we’re processing 1000 requests per second with 100 of these API calls per request, then we are throwing 1000 times a second.  That’s a very disturbing rate of exceptions.  On the other hand, a 1% failure rate may be quite tolerable in a client scenario, if the exception occurs when a human user presses the wrong button.

Sometimes you won’t know whether your API will be used in a client or a server.  And it may be hard for you to predict failure rates when errors are triggered by bad data from the client.  If you’ve provided a way for the client to check his data without triggering an exception (like the TryParse() example above) then you’ve done your part.

As usual, there’s so much more to say.  I still haven’t talked about unhandled exceptions.  Or about undeniable exception propagation (Thread.Abort).  Or how undeniable propagation interacts with propagation through unmanaged code via PInvoke, IJW or COM Interop.  And I carefully avoided explaining why we didn’t follow our own rules when defining and using the Exception class hierarchy.  And there’s plenty to say about our special treatment of OutOfMemoryException and StackOverflowException.

If you are still reading and actually want to know more, perhaps you should just apply for a job on the CLR team.
