//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
#if compiler(>=5.5.2) && canImport(_Concurrency)
import Atomics
import Dispatch
import _NIODataStructures
import NIOCore
import NIOConcurrencyHelpers


/// An `EventLoop` that is thread safe and whose execution is fully controlled
/// by the user.
///
/// Unlike more complex `EventLoop`s, such as `SelectableEventLoop`, the `NIOAsyncEmbeddedEventLoop`
/// has no proper eventing mechanism. Instead, reads and writes are fully controlled by the
/// entity that instantiates the `NIOAsyncEmbeddedEventLoop`. This property makes `NIOAsyncEmbeddedEventLoop`
/// of limited use for many application purposes, but highly valuable for testing and other
/// kinds of mocking. Unlike `EmbeddedEventLoop`, `NIOAsyncEmbeddedEventLoop` is fully thread-safe and
/// safe to use from within a Swift concurrency context.
///
/// Unlike `EmbeddedEventLoop`, `NIOAsyncEmbeddedEventLoop` does require that user tests appropriately
/// enforce thread safety. Used carefully it is possible to safely operate the event loop without
/// explicit synchronization, but it is recommended to use `executeInContext` in any case where it's
/// necessary to ensure that the event loop is not making progress.
///
/// Time is controllable on an `NIOAsyncEmbeddedEventLoop`. It begins at `NIODeadline.uptimeNanoseconds(0)`
/// and may be advanced by a fixed amount by using `advanceTime(by:)`, or advanced to a point in
/// time with `advanceTime(to:)`.
///
/// If users wish to perform multiple tasks at once on an `NIOAsyncEmbeddedEventLoop`, it is recommended that they
/// use `executeInContext` to perform the operations. For example:
///
/// ```
/// await loop.executeInContext {
///     // All three of these will be queued up simultaneously, and no other code can
///     // get between them.
///     loop.execute { firstTask() }
///     loop.execute { secondTask() }
///     loop.execute { thirdTask() }
/// }
/// ```
///
/// There is a tricky requirement around waiting for `EventLoopFuture`s when working with this
/// event loop. Simply calling `.wait()` from the test thread will never complete. This is because
/// `wait` calls `loop.execute` under the hood, and that callback cannot execute without calling
/// `loop.run()`. As a result, if you need to await an `EventLoopFuture` created on this loop you
/// should use `awaitFuture`.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public final class NIOAsyncEmbeddedEventLoop: EventLoop, @unchecked Sendable {
    // This type is `@unchecked Sendable` because of the use of `taskNumber`. This
    // variable is only used from within `queue`, but the compiler cannot see that.

    /// The current "time" for this event loop. This is an amount in nanoseconds.
    /// As we need to access this from any thread, we store this as an atomic.
    private let _now = ManagedAtomic<UInt64>(0)
    internal var now: NIODeadline {
        return NIODeadline.uptimeNanoseconds(self._now.load(ordering: .relaxed))
    }

    /// This is used to derive an identifier for this loop.
    private var thisLoopID: ObjectIdentifier {
        return ObjectIdentifier(self)
    }

    /// A dispatch specific that we use to determine whether we are on the queue for this
    /// "event loop".
    private static let inQueueKey = DispatchSpecificKey<ObjectIdentifier>()

    // Our scheduledTaskCounter needs to be an atomic because we're going to access it from
    // arbitrary threads. This is required by the EventLoop protocol and cannot be avoided.
    // Specifically, Scheduled<T> creation requires us to be able to define the cancellation
    // operation, so the task ID has to be created early.
    private let scheduledTaskCounter = ManagedAtomic<UInt64>(0)
    private var scheduledTasks = PriorityQueue<EmbeddedScheduledTask>()

    /// Keep track of where promises are allocated to ensure we can identify their source if they leak.
    private let _promiseCreationStore = PromiseCreationStore()

    // The number of the next task to be created. We track the order so that when we execute tasks
    // scheduled at the same time, we may do so in the order in which they were submitted for
    // execution.
    //
    // This can only be accessed from `queue`
    private var taskNumber = UInt64(0)

    /// The queue on which we run all our operations.
    private let queue = DispatchQueue(label: "io.swiftnio.AsyncEmbeddedEventLoop")

    // This function must only be called on queue.
    private func nextTaskNumber() -> UInt64 {
        dispatchPrecondition(condition: .onQueue(self.queue))
        defer {
            self.taskNumber += 1
        }
        return self.taskNumber
    }

    /// - see: `EventLoop.inEventLoop`
    public var inEventLoop: Bool {
        return DispatchQueue.getSpecific(key: Self.inQueueKey) == self.thisLoopID
    }

    /// Initialize a new `NIOAsyncEmbeddedEventLoop`.
    public init() {
        self.queue.setSpecific(key: Self.inQueueKey, value: self.thisLoopID)
    }

    private func removeTask(taskID: UInt64) {
        dispatchPrecondition(condition: .onQueue(self.queue))
        self.scheduledTasks.removeFirst { $0.id == taskID }
    }

    private func insertTask<ReturnType>(
        taskID: UInt64,
        deadline: NIODeadline,
        promise: EventLoopPromise<ReturnType>,
        task: @escaping () throws -> ReturnType
    ) {
        dispatchPrecondition(condition: .onQueue(self.queue))

        let task = EmbeddedScheduledTask(id: taskID, readyTime: deadline, insertOrder: self.nextTaskNumber(), task: {
            do {
                promise.succeed(try task())
            } catch let err {
                promise.fail(err)
            }
        }, promise.fail)

        self.scheduledTasks.push(task)
    }

    /// - see: `EventLoop.scheduleTask(deadline:_:)`
    @discardableResult
    public func scheduleTask<T>(deadline: NIODeadline, _ task: @escaping () throws -> T) -> Scheduled<T> {
        let promise: EventLoopPromise<T> = self.makePromise()
        let taskID = self.scheduledTaskCounter.loadThenWrappingIncrement(ordering: .relaxed)

        let scheduled = Scheduled(promise: promise, cancellationTask: {
            if self.inEventLoop {
                self.removeTask(taskID: taskID)
            } else {
                self.queue.async {
                    self.removeTask(taskID: taskID)
                }
            }
        })

        if self.inEventLoop {
            self.insertTask(taskID: taskID, deadline: deadline, promise: promise, task: task)
        } else {
            self.queue.async {
                self.insertTask(taskID: taskID, deadline: deadline, promise: promise, task: task)
            }
        }
        return scheduled
    }

    /// - see: `EventLoop.scheduleTask(in:_:)`
    @discardableResult
    public func scheduleTask<T>(in: TimeAmount, _ task: @escaping () throws -> T) -> Scheduled<T> {
        return self.scheduleTask(deadline: self.now + `in`, task)
    }

    /// On an `NIOAsyncEmbeddedEventLoop`, `execute` will simply use `scheduleTask` with a deadline of _now_. This means that
    /// `task` will be run the next time you call `AsyncEmbeddedEventLoop.run`.
    public func execute(_ task: @escaping () -> Void) {
        self.scheduleTask(deadline: self.now, task)
    }

    /// Run all tasks that have previously been submitted to this `NIOAsyncEmbeddedEventLoop`, either by calling `execute` or
    /// events that have been enqueued using `scheduleTask`/`scheduleRepeatedTask`/`scheduleRepeatedAsyncTask` and whose
    /// deadlines have expired.
    ///
    /// - seealso: `NIOAsyncEmbeddedEventLoop.advanceTime`.
    public func run() async {
        // Execute all tasks that are currently enqueued to be executed *now*.
        await self.advanceTime(to: self.now)
    }

    /// Runs the event loop and moves "time" forward by the given amount, running any scheduled
    /// tasks that need to be run.
    public func advanceTime(by increment: TimeAmount) async {
        await self.advanceTime(to: self.now + increment)
    }

    /// Unwrap a future result from this event loop.
    ///
    /// This replaces `EventLoopFuture.get()` for use with `NIOAsyncEmbeddedEventLoop`. This is necessary because attaching
    /// a callback to an `EventLoopFuture` (which is what `EventLoopFuture.get` does) requires scheduling a work item onto
    /// the event loop, and running that work item requires spinning the loop. This is a non-trivial dance to get right due
    /// to timing issues, so this function provides a helper to ensure that this will work.
    public func awaitFuture<ResultType: Sendable>(_ future: EventLoopFuture<ResultType>, timeout: TimeAmount) async throws -> ResultType {
        // We need a task group to wait for the scheduled future result, because the future result callback
        // can only complete when we actually run the loop, which we need to do in another Task.
        return try await withThrowingTaskGroup(of: ResultType.self, returning: ResultType.self) { group in
            // We need an innner promise to allow cancellation of the wait.
            let promise = self.makePromise(of: ResultType.self)
            future.cascade(to: promise)

            group.addTask {
                try await promise.futureResult.get()
            }

            group.addTask {
                while true {
                    await self.run()
                    try Task.checkCancellation()
                    await Task.yield()
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout.nanoseconds))
                promise.fail(NIOAsyncEmbeddedEventLoopError.timeoutAwaitingFuture)

                // This self.run() is _very important_. We're about to throw out of this function, which will
                // cancel the entire TaskGroup. Depending on how things get scheduled it is possible for that
                // cancellation to cancel the runner task above _before_ it spins again, meaning that the
                // promise failure never actually happens (as it has to establish event loop context). So
                // before we cancel this we make sure that we get a chance to spin the loop.
                await self.run()
                throw NIOAsyncEmbeddedEventLoopError.timeoutAwaitingFuture
            }

            do {
                // This force-unwrap is safe: there are only three tasks and only one of them can ever return a value,
                // the rest will error. The one that does return a value can never return `nil`. In essence, this is an
                // `AsyncSequenceOfOneOrError`.
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    /// Runs the event loop and moves "time" forward to the given point in time, running any scheduled
    /// tasks that need to be run.
    ///
    /// - Note: If `deadline` is before the current time, the current time will not be advanced.
    public func advanceTime(to deadline: NIODeadline) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.queue.async {
                let newTime = max(deadline, self.now)

                var tasks = CircularBuffer<EmbeddedScheduledTask>()
                while let nextTask = self.scheduledTasks.peek() {
                    guard nextTask.readyTime <= newTime else {
                        break
                    }

                    // Now we want to grab all tasks that are ready to execute at the same
                    // time as the first.
                    while let candidateTask = self.scheduledTasks.peek(), candidateTask.readyTime == nextTask.readyTime {
                        tasks.append(candidateTask)
                        self.scheduledTasks.pop()
                    }

                    // Set the time correctly before we call into user code, then
                    // call in for all tasks.
                    self._now.store(nextTask.readyTime.uptimeNanoseconds, ordering: .relaxed)

                    for task in tasks {
                        task.task()
                    }

                    tasks.removeAll(keepingCapacity: true)
                }

                // Finally ensure we got the time right.
                self._now.store(newTime.uptimeNanoseconds, ordering: .relaxed)

                continuation.resume()
            }
        }
    }

    /// Executes the given function in the context of this event loop. This is useful when it's necessary to be confident that an operation
    /// is "blocking" the event loop. As long as you are executing, nothing else can execute in this loop.
    ///
    /// While this call is running, no action can take place on the loop. This function can therefore be a good place to schedule a bunch
    /// of tasks "at once", with a guarantee that none of them can progress. It's also useful if you have types that can only be safely
    /// accessed from the event loop thread and want to be 100% sure of the thread-safety of accessing them.
    ///
    /// Be careful not to try to spin the event loop again from within this callback, however. As long as this function is on the call
    /// stack the `NIOAsyncEmbeddedEventLoop` cannot progress, and so any attempt to progress it will block until this function returns.
    public func executeInContext<ReturnType: Sendable>(_ task: @escaping @Sendable () throws -> ReturnType) async throws -> ReturnType {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ReturnType, Error>) in
            self.queue.async {
                do {
                    continuation.resume(returning: try task())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    internal func drainScheduledTasksByRunningAllCurrentlyScheduledTasks() {
        var currentlyScheduledTasks = self.scheduledTasks
        while let nextTask = currentlyScheduledTasks.pop() {
            self._now.store(nextTask.readyTime.uptimeNanoseconds, ordering: .relaxed)
            nextTask.task()
        }
        // Just fail all the remaining scheduled tasks. Despite having run all the tasks that were
        // scheduled when we entered the method this may still contain tasks as running the tasks
        // may have enqueued more tasks.
        while let task = self.scheduledTasks.pop() {
            task.fail(EventLoopError.shutdown)
        }
    }

    private func _shutdownGracefully() {
        dispatchPrecondition(condition: .onQueue(self.queue))
        self.drainScheduledTasksByRunningAllCurrentlyScheduledTasks()
    }

    /// - see: `EventLoop.shutdownGracefully`
    public func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        self.queue.async {
            self._shutdownGracefully()
            queue.async {
                callback(nil)
            }
        }
    }

    /// The concurrency-aware equivalent of `shutdownGracefully(queue:_:)`.
    public func shutdownGracefully() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.queue.async {
                self._shutdownGracefully()
                continuation.resume()
            }
        }
    }

    public func _preconditionSafeToWait(file: StaticString, line: UInt) {
        dispatchPrecondition(condition: .notOnQueue(self.queue))
    }

    public func _promiseCreated(futureIdentifier: _NIOEventLoopFutureIdentifier, file: StaticString, line: UInt) {
        self._promiseCreationStore.promiseCreated(futureIdentifier: futureIdentifier, file: file, line: line)
    }

    public func _promiseCompleted(futureIdentifier: _NIOEventLoopFutureIdentifier) -> (file: StaticString, line: UInt)? {
        return self._promiseCreationStore.promiseCompleted(futureIdentifier: futureIdentifier)
    }

    public func _preconditionSafeToSyncShutdown(file: StaticString, line: UInt) {
        dispatchPrecondition(condition: .notOnQueue(self.queue))
    }

    public func preconditionInEventLoop(file: StaticString, line: UInt) {
        dispatchPrecondition(condition: .onQueue(self.queue))
    }

    public func preconditionNotInEventLoop(file: StaticString, line: UInt) {
        dispatchPrecondition(condition: .notOnQueue(self.queue))
    }

    deinit {
        precondition(scheduledTasks.isEmpty, "NIOAsyncEmbeddedEventLoop freed with unexecuted scheduled tasks!")
    }
}

/// This is a thread-safe promise creation store.
///
/// We use this to keep track of where promises come from in the `NIOAsyncEmbeddedEventLoop`.
private class PromiseCreationStore {
    private let lock = Lock()
    private var promiseCreationStore: [_NIOEventLoopFutureIdentifier: (file: StaticString, line: UInt)] = [:]

    func promiseCreated(futureIdentifier: _NIOEventLoopFutureIdentifier, file: StaticString, line: UInt) {
        precondition(_isDebugAssertConfiguration())
        self.lock.withLockVoid {
            self.promiseCreationStore[futureIdentifier] = (file: file, line: line)
        }
    }

    func promiseCompleted(futureIdentifier: _NIOEventLoopFutureIdentifier) -> (file: StaticString, line: UInt)? {
        precondition(_isDebugAssertConfiguration())
        return self.lock.withLock {
            self.promiseCreationStore.removeValue(forKey: futureIdentifier)
        }
    }

    deinit {
        // We no longer need the lock here.
        precondition(self.promiseCreationStore.isEmpty, "NIOAsyncEmbeddedEventLoop freed with uncompleted promises!")
    }
}

/// Errors that can happen on a `NIOAsyncEmbeddedEventLoop`.
public struct NIOAsyncEmbeddedEventLoopError: Error, Hashable {
    private enum Backing {
        case timeoutAwaitingFuture
    }

    private var backing: Backing

    private init(_ backing: Backing) {
        self.backing = backing
    }

    /// A timeout occurred while waiting for a future to complete.
    public static let timeoutAwaitingFuture = Self(.timeoutAwaitingFuture)
}

#endif
