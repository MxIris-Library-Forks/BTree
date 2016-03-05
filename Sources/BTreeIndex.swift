//
//  BTreeIndex.swift
//  BTree
//
//  Created by Károly Lőrentey on 2016-02-11.
//  Copyright © 2015–2016 Károly Lőrentey.
//

/// An index into a collection that uses a B-tree for storage.
///
/// This index satisfies `CollectionType`'s requirement for O(1) access, but
/// it is only suitable for read-only processing -- most tree mutations will 
/// invalidate all existing indexes.
/// 
/// - SeeAlso: `BTreeCursor` for an efficient way to modify a batch of values in a B-tree.
public struct BTreeIndex<Key: Comparable, Payload>: BidirectionalIndexType, Comparable {
    public typealias Distance = Int
    typealias Node = BTreeNode<Key, Payload>
    typealias State = BTreeWeakPath<Key, Payload>

    internal private(set) var state: State

    internal init(_ state: State) {
        self.state = state
    }
    
    /// Advance to the next index.
    ///
    /// - Requires: self is valid and not the end index.
    /// - Complexity: Amortized O(1).
    public mutating func successorInPlace() {
        state.moveForward()
    }
    
    /// Advance to the previous index.
    ///
    /// - Requires: self is valid and not the start index.
    /// - Complexity: Amortized O(1).
    public mutating func predecessorInPlace() {
        state.moveBackward()
    }

    /// Advance this index by `distance` elements.
    ///
    /// - Complexity: O(log(*n*)) where *n* is the number of elements in the tree.
    public mutating func advance(by distance: Int) {
        state.move(toPosition: state.position + distance)
    }

    /// Return the next index after `self` in its collection.
    ///
    /// - Requires: self is valid and not the end index.
    /// - Complexity: Amortized O(1).
    @warn_unused_result
    public func successor() -> BTreeIndex {
        var result = self
        result.successorInPlace()
        return result
    }

    /// Return the index preceding `self` in its collection.
    ///
    /// - Requires: self is valid and not the start index.
    /// - Complexity: Amortized O(1).
    @warn_unused_result
    public func predecessor() -> BTreeIndex {
        var result = self
        result.predecessorInPlace()
        return result
    }

    /// Return the result of advancing `self` by `n` positions.
    /// 
    /// - Complexity: O(log(`n`))
    @warn_unused_result
    public func advancedBy(n: Int) -> BTreeIndex {
        var result = self
        result.advance(by: n)
        return result
    }

    /// Return the result of advancing `self` by `n` positions.
    ///
    /// - Complexity: O(log(`n`))
    @warn_unused_result
    public func advancedBy(n: Int, limit: BTreeIndex) -> BTreeIndex {
        state.expectRoot(limit.state.root)
        let d = self.distanceTo(limit)
        if d == 0 || (d > 0 ? d <= n : d >= n) {
            return limit
        }
        return self.advancedBy(n)
    }

    /// Return the result of advancing self by `n` positions, or until it equals `limit`.
    ///
    /// - Complexity: O(1)
    @warn_unused_result
    public func distanceTo(end: BTreeIndex) -> Int {
        state.expectRoot(end.state.root)
        return end.state.position - state.position
    }
}

/// Return true iff `a` is equal to `b`.
@warn_unused_result
public func == <Key: Comparable, Payload>(a: BTreeIndex<Key, Payload>, b: BTreeIndex<Key, Payload>) -> Bool {
    guard let ar = a.state._root.value else { a.state.invalid() }
    guard let br = b.state._root.value else { b.state.invalid() }
    precondition(ar === br, "Indices to different trees cannot be compared")
    return a.state.position == b.state.position
}

/// Return true iff `a` is less than `b`.
@warn_unused_result
public func < <Key: Comparable, Payload>(a: BTreeIndex<Key, Payload>, b: BTreeIndex<Key, Payload>) -> Bool {
    guard let ar = a.state._root.value else { a.state.invalid() }
    guard let br = b.state._root.value else { b.state.invalid() }
    precondition(ar === br, "Indices to different trees cannot be compared")
    return a.state.position < b.state.position
}

/// A mutable path in a B-tree, holding weak references to nodes on the path.
/// This path variant does not support modifying the tree itself; it is suitable for use in indices.
///
/// After a path of this kind has been created, the original tree might mutated in a way that invalidates
/// the path, setting some of its weak references to nil, or breaking the consistency of its trail of slot indices.
/// The path checks for this during navigation, and traps if it finds itself invalidated.
///
internal struct BTreeWeakPath<Key: Comparable, Payload>: BTreePath {
    typealias Node = BTreeNode<Key, Payload>

    var _root: Weak<Node>
    var position: Int

    var _path: [Weak<Node>]
    var _slots: [Int]
    var _node: Weak<Node>
    var slot: Int?

    init(_ root: Node) {
        self._root = Weak(root)
        self.position = root.count
        self._path = []
        self._slots = []
        self._node = Weak(root)
        self.slot = nil
    }

    var root: Node {
        guard let root = _root.value else { invalid() }
        return root
    }
    var count: Int { return root.count }
    var length: Int { return _path.count + 1}

    var node: Node {
        guard let node = _node.value else { invalid() }
        return node
    }
    
    internal func expectRoot(root: Node) {
        expectValid(_root.value === root)
    }

    internal func expectValid(@autoclosure expression: Void->Bool, file: StaticString = __FILE__, line: UInt = __LINE__) {
        precondition(expression(), "Invalid BTreeIndex", file: file, line: line)
    }

    @noreturn internal func invalid(file: StaticString = __FILE__, line: UInt = __LINE__) {
        preconditionFailure("Invalid BTreeIndex", file: file, line: line)
    }

    mutating func popFromSlots() {
        assert(self.slot != nil)
        let node = self.node
        position += node.count - node.positionOfSlot(slot!)
        slot = nil
    }

    mutating func popFromPath() {
        assert(_path.count > 0 && slot == nil)
        let child = node
        _node = _path.removeLast()
        expectValid(node.children[_slots.last!] === child)
        slot = _slots.removeLast()
    }

    mutating func pushToPath() {
        assert(self.slot != nil)
        let child = node.children[slot!]
        _path.append(_node)
        _node = Weak(child)
        _slots.append(slot!)
        slot = nil
    }

    mutating func pushToSlots(slot: Int, positionOfSlot: Int) {
        assert(self.slot == nil)
        position -= node.count - positionOfSlot
        self.slot = slot
    }

    func forEach(ascending ascending: Bool, @noescape body: (Node, Int) -> Void) {
        if ascending {
            var child: Node? = node
            body(child!, slot!)
            for i in (0 ..< _path.count).reverse() {
                guard let node = _path[i].value else { invalid() }
                let slot = _slots[i]
                expectValid(node.children[slot] === child)
                child = node
                body(node, slot)
            }
        }
        else {
            for i in 0 ..< _path.count {
                guard let node = _path[i].value else { invalid() }
                let slot = _slots[i]
                expectValid(node.children[slot] === (i < _path.count - 1 ? _path[i + 1].value : _node.value))
                body(node, slot)
            }
            body(node, slot!)
        }
    }

    func forEachSlot(ascending ascending: Bool, @noescape body: Int -> Void) {
        if ascending {
            body(slot!)
            _slots.reverse().forEach(body)
        }
        else {
            _slots.forEach(body)
            body(slot!)
        }
    }
}
