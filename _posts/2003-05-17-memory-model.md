---
layout: post
title: Memory Model
permalink: memory-model
date: 2003-05-17 18:56:00.000000000 -07:00
status: publish
type: post
published: true
---

One of the suggestions for a blog entry was the managed memory model.  This is timely, because we’ve just been revising our overall approach to this confusing topic.  For the most part, I write about product decisions that have already been made and shipped.  In this note, I’m talking about future directions.  Be skeptical.

So what is a memory model?  It’s the abstraction that makes the reality of today’s exotic hardware comprehensible to software developers.

The reality of hardware is that CPUs are renaming registers, performing speculative and out-of-order execution, and fixing up the world during retirement.  Memory state is cached at various levels in the system (L0 thru L3 on modern X86 boxes, presumably with more levels on the way).  Some levels of cache are shared between particular CPUs but not others.  For example, L0 is typically per-CPU but a hyper-threaded CPU may share L0 between the logical CPUs of a single physical CPU.  Or an 8-way box may split the system into two hemispheres with cache controllers performing an elaborate coherency protocol between these separate hemispheres.  If you consider caching effects, at some level all MP (multi-processor) computers are NUMA (non-uniform memory access).  But there’s enough magic going on that even a Unisys 32-way can generally be considered as UMA by developers.

It’s reasonable for the CLR to know as much as possible about the cache architecture of your hardware so that it can exploit any imbalances.  For example, the developers on our performance team have experimented with a scalable rendezvous for phases of the GC.  The idea was that each CPU establishes a rendezvous with the CPU that is “closest” to it in distance in the cache hierarchy, and then one of this pair cascades up a tree to its closest neighbor until we reach a single root CPU.  At that point, the rendezvous is complete.  I think the jury is still out on this particular technique, but they have found some other techniques that really pay off on the larger systems.

Of course, it’s absolutely unreasonable for any managed developer (or 99.99% of unmanaged developers) to ever concern themselves with these imbalances.  Instead, software developers want to treat all computers as equivalent.  For managed developers, the CLR is the computer and it better work consistently regardless of the underlying machine.

> Although managed developers shouldn’t know the difference between a 4-way AMD server and an Intel P4 hyper-threaded dual proc, they still need to face the realities of today’s hardware.  Today, I think the penalty of a CPU cache miss that goes all the way to main memory is about 1/10th the penalty of a memory miss that goes all the way to disk.  And the trend is clear.
>
> If you wanted good performance on a virtual memory system, you’ve always been responsible for relieving the paging system by getting good page density and locality in your data structures and access patterns.
>
> In a similar vein, if you want good performance on today’s hardware, where accessing main memory is a small disaster, you must pack your data into cache lines and limit indirections.  If you are building shared data structures, consider separating any data that’s subject to false sharing.
>
> To some extent, the CLR can help you here.  On MP machines, we use lock-free allocators which (statistically) guarantee locality for each thread’s allocations.  Any compaction will (statistically) preserve that locality.  Looking into the very far future – perhaps after our sun explodes – you could imagine a CLR that can reorganize your data structures to achieve even better performance.
>
> This means that if you are writing single-threaded managed code to process a server request, and if you can avoid writing to any shared state, you are probably going to be pretty scalable without even trying.

Getting back to memory models, what is the abstraction that will make sense of current hardware?  It’s a simplifying model where all the cache levels disappear.  We pretend that all the CPUs are attached to a single shared memory.  Now we just need to know whether all the CPUs see the same state in that memory, or if it’s possible for some of them to see reordering in the loads and stores that occur on other CPUs.

At one extreme, we have a world where all the CPUs see a single consistent memory.  All the loads and stores expressed in programs are performed in a serialized manner and nobody perceives a particular thread’s loads or stores being reordered.  That’s a wonderfully sane model which is easy for software developers to comprehend and program to.  Unfortunately, it is far too slow and non-scalable.  Nobody builds this.

At the other extreme, we have a world where CPUs operate almost entirely out of private cache.  If another CPU ever sees anything my CPU is doing, it’s a total accident of timing.  Because loads and stores can propagate to other CPUs in any random order, performance and scaling are great.  But it is impossible for humans to program to this model.

In between those extremes are a lot of different possibilities.  Those possibilities are explained in terms of acquire and release semantics:

* A normal load or store can be freely reordered with respect to other normal load or store operations.
* A load with acquire semantics creates a downwards fence.  This means that normal loads and stores can be moved down past the load.acquire, but nothing can be moved to above the load.acquire.
* A store with release semantics creates an upwards fence.  This means that normal loads and stores can be moved above the store.release, but nothing can be moved to below the store.release.
* A full fence is effectively an upwards and downwards fence.  Nothing can move in either direction across a full fence.

A super-strong extreme model puts a full fence after every load or store.  A super-weak extreme model uses normal loads and stores everywhere, with no fencing.

The most familiar model is X86.  It’s a relatively strong model.  Stores are never reordered with respect to other stores.  But, in the absence of data dependence, loads can be reordered with respect to other loads and stores.  Many X86 developers don’t realize that this reordering is possible, though it can lead to some nasty failures under stress on big MP machines.

In terms of the above, the memory model for X86 can be described as:

1. All stores are actually store.release.
2. All loads are normal loads.
3. Any use of the LOCK prefix (e.g. ‘LOCK CMPXCHG’ or ‘LOCK INC’) creates a full fence.

Historically, Windows NT has run on Alpha and MIPS computers.

Looking forwards, Microsoft has announced that Windows will support Intel’s IA64 and AMD’s AMD64 processors.  Eventually, we need to port the CLR to wherever Windows runs.  You can draw an obvious conclusion from these facts.

AMD64 has the same memory model as X86.

IA64 specifies a weaker memory model than X86.  Specifically, all loads and stores are normal loads and stores.  The application must use special ld.acq and st.rel instructions to achieve acquire and release semantics.  There’s also a full fence instruction, though I can’t remember the opcode (mf?).

Be especially skeptical when you read the next paragraph:

There’s some reason to believe that current IA64 hardware actually implements a stronger model than is specified.  Based on informed hearsay and lots of experimental evidence, it looks like normal store instructions on current IA64 hardware are retired in order with release semantics.

If this is indeed the case, why would Intel specify something weaker than what they have built?  Presumably they would do this to leave the door open for a weaker (i.e. faster and more scalable) implementation in the future.

In fact, the CLR has done exactly the same thing.  Section 12.6 of Partition I of the ECMA CLI specification explains our memory model.  This explains the alignment rules, byte ordering, the atomicity of loads and stores, volatile semantics, locking behavior, etc.  According to that specification, an application must use volatile loads and volatile stores to achieve acquire and release semantics.  Normal loads and stores can be freely reordered, as seen by other CPUs.

What is the practical implication of this?  Consider the standard double-locking protocol:

```
if (a == null)
{
  lock(obj)
  {
    if (a == null) a = new A();
  }
}
```

This is a common technique for avoiding a lock on the read of ‘a’ in the typical case.  It works just fine on X86.  But it would be broken by a legal but weak implementation of the ECMA CLI spec.  It’s true that, according to the ECMA spec, acquiring a lock has acquire semantics and releasing a lock has release semantics.

However, we have to assume that a series of stores have taken place during construction of ‘a’.  Those stores can be arbitrarily reordered, including the possibility of delaying them until after the publishing store which assigns the new object to ‘a’.  At that point, there is a small window before the store.release implied by leaving the lock.  Inside that window, other CPUs can navigate through the reference ‘a’ and see a partially constructed instance.

We could fix this code in various ways.  For example, we could insert a memory barrier of some sort after construction and before assignment to ‘a’.  Or – if construction of ‘a’ has no side effects – we could move the assignment outside the lock, and use an Interlocked.CompareExchange to ensure that assignment only happens once.  The GC would collect any extra ‘A’ instances created by this race.

I hope that this example has convinced you that you don’t want to try writing reliable code against the documented CLI model.

I wrote a fair amount of “clever” lock-free thread-safe code in version 1 of the CLR.  This included techniques like lock-free synchronization between the class loader, the prestub (which traps first calls on methods so it can generate code for them), and AppDomain unloading so that I could back-patch MethodTable slots efficiently.  But I have no desire to write any kind of code on a system that’s as weak as the ECMA CLI spec.

Even if I tried to write code that is robust under that memory model, I have no hardware that I could test it on.  X86, AMD64 and (presumably) IA64 are stronger than what we specified.

In my opinion, we screwed up when we specified the ECMA memory model.  That model is unreasonable because:

* All stores to shared memory really require a volatile prefix.
* This is not a productive way to code.
* Developers will often make mistakes as they follow this onerous discipline.
* These mistakes cannot be discovered through testing, because the hardware is too strong.

So what would make a sensible memory model for the CLR?

Well, first we would want to have a consistent model across all CLI implementations.  This would include the CLR, Rotor, the Compact Frameworks, SPOT, and – ideally – non-Microsoft implementations like Mono.  So putting a common memory model into an ECMA spec was definitely a good idea.

It goes without saying that this model should be consistent across all possible CPUs.  We’re in big trouble if everyone is testing on X86 but then deploying on Alpha (which had a notoriously weak model).

We would also want to have a consistent model between the native code generator (JIT or NGEN) and the CPU.  It doesn’t make sense to constrain the JIT or NGEN to order stores, but then allow the CPU to reorder those stores.  Or vice versa.

Ideally, the IL generator would also follow the same model.  In other words, your C# compiler should be allowed to reorder whatever the native code generator and CPU are allowed to reorder.  There’s some debate whether the converse is true.  Arguably, it is okay for an IL generator to apply more aggressive optimizations than the native code generator and CPU are permitted, because IL generation occurs on the developer’s box and is subject to testing.

Ultimately, that last point is a language decision rather than a CLR decision.  Some IL generators, like ILASM, will rigorously emit IL in the sequence specified by the source code.  Other IL generators, like Managed C++, might pursue aggressive reordering based on their own language rules and compiler optimization switches.  If I had to guess, IL generators like the Microsoft compilers for C# and VB.NET would decide to respect the CLR’s memory model.

We’ve spent a lot of time thinking about what the correct memory model for the CLR should be.  If I had to guess, we’re going to switch from the ECMA model to the following model.  I think that we will try to persuade other CLI implementations to adopt this same model, and that we will try to change the ECMA specification to reflect this.

1. Memory ordering only applies to locations which can be globally visible or locations that are marked volatile.  Any locals that are not address exposed can be optimized without using memory ordering as a constraint since these locations cannot be touched by multiple threads in parallel.
2. Non-volatile loads can be reordered freely.
3. Every store (regardless of volatile marking) is considered a release.
4. Volatile loads are considered acquire.
5. Device oriented software may need special programmer care.  Volatile stores are still required for any access of device memory.  This is typically not a concern for the managed developer.

If you’re thinking this looks an awful lot like X86, AMD64 and (presumably) IA64, you are right.  We also think it hits the sweet spots for compilers.  Reordering loads is much more important for enabling optimizations than reordering stores.

So what happens in 10 years when these architectures are gone and we’re all using futuristic Starbucks computers with an ultra-weak model?  Well, hopefully I’ll be living the good life in retirement on Maui.  But the CLR’s native code generators will generate whatever instructions are necessary to keep stores ordered when executing your existing programs.  Obviously this will sacrifice some performance.

The trade-off between developer productivity and computer performance is really an economic one.  If there’s sufficient incentive to write code to a weak memory model so it can execute efficiently on future computers, then developers will do so.  At that point, we will allow them to mark their assemblies (or individual methods) to indicate that they are “weak model clean”.  This will permit the native code generator to emit normal stores rather than store.release instructions.  You’ll be able to achieve high performance on weak machines, but this will always be “opt in”.  And we won’t build this capability until there’s a real demand for it.

I personally believe that for mainstream computing, weak memory models will never catch on with human developers.  Human productivity and software reliability are more important than the increment of performance and scaling these models provide.

Finally, I think the person asking about memory models was really interested in where he should use volatile and fences in his code.  Here’s my advice:

* Use managed locks like Monitor.Enter (C# lock / VB.NET synclock) for synchronization, except where performance really requires you to be “clever”.
* When you’re being “clever”, assume the relatively strong model I described above.  Only loads are subject to re-ordering.
* If you have more than a few places that you are using volatile, you’re probably being too clever.  Consider backing off and using managed locks instead.
* Realize that synchronization is expensive.  The full fence implied by Interlocked.Increment can be many 100’s of cycles on modern hardware.  That penalty may continue to grow, in relative terms.
* Consider locality and caching effects like hot spots due to false sharing.
* Stress test for days with the biggest MP box you can get your hands on.
* Take everything I said with a grain of salt.
