import assert from "node:assert/strict"
import {test} from "node:test"
import {scaleElement} from "./diagram_geometry.js"
import {
  canGroup,
  canRestack,
  canUngroup,
  existingPath,
  group,
  restack,
  selectionLevel,
  tidyGroups,
  ungroup,
  unitAt,
  wholeGroups,
} from "./diagram_groups.js"

// Boxes on a row, far enough apart that none overlaps another, unless
// placed at the same `x`.
const box = (id, groups = [], x = 0) => ({
  id, type: "rectangle", x, y: 0, width: 10, height: 10, ...(groups.length && {groups}),
})
const ids = (elements) => elements.map((element) => element.id)
const picked = (...list) => new Set(list)

test("a group's members are gathered where the topmost of them is", () => {
  const elements = [box("a", ["g"]), box("b"), box("c", ["g"]), box("d")]
  assert.deepEqual(ids(tidyGroups(elements)), ["b", "a", "c", "d"])
})

test("nested groups are gathered inside their group", () => {
  const elements = [box("a", ["g", "h"]), box("b", ["g"]), box("c", ["g", "h"]), box("d"), box("e", ["g"])]
  // g goes where e is, and h inside it where c is.
  assert.deepEqual(ids(tidyGroups(elements)), ["d", "b", "a", "c", "e"])
})

test("a group listed inside different groups keeps its first place", () => {
  const elements = [box("a", ["g", "h"]), box("b", ["g", "h"]), box("c", ["h"]), box("d", ["x", "h"])]
  const tidy = tidyGroups(elements)
  assert.deepEqual(tidy.map((element) => element.groups), [["g", "h"], ["g", "h"], undefined, undefined])
})

test("a group with one member left is no group, nor any inside it", () => {
  const elements = [box("a", ["g", "h"]), box("b", ["x"]), box("c", ["x"])]
  const tidy = tidyGroups(elements)
  assert.deepEqual(tidy.map((element) => element.groups), [undefined, ["x"], ["x"]])
})

test("a group listed twice by one element is kept once", () => {
  const tidy = tidyGroups([box("a", ["g", "g"]), box("b", ["g"])])
  assert.deepEqual(tidy.map((element) => element.groups), [["g"], ["g"]])
})

test("a member picks its whole group, and inside it, itself", () => {
  const elements = [box("a", ["g", "h"]), box("b", ["g", "h"]), box("c", ["g"])]
  assert.deepEqual(ids(unitAt(elements, elements[0], [])), ["a", "b", "c"])
  assert.deepEqual(ids(unitAt(elements, elements[0], ["g"])), ["a", "b"])
  assert.deepEqual(ids(unitAt(elements, elements[0], ["g", "h"])), ["a"])
})

test("the level of a selection stops short of a group picked whole", () => {
  const elements = [box("a", ["g", "h"]), box("b", ["g", "h"]), box("c", ["g"])]
  assert.deepEqual(selectionLevel(elements, picked("a", "b", "c")), [])
  assert.deepEqual(selectionLevel(elements, picked("a", "b")), ["g"])
  assert.deepEqual(selectionLevel(elements, picked("a")), ["g", "h"])
  assert.deepEqual([...wholeGroups(elements, picked("a", "b"))], ["h"])
})

test("grouping puts a group around whole units, inside their level", () => {
  const elements = [box("a", ["g"]), box("b", ["g"]), box("c"), box("d")]
  const grouped = group(elements, picked("a", "b", "d"), "n")
  assert.deepEqual(ids(grouped), ["c", "a", "b", "d"])
  assert.deepEqual(grouped.map((element) => element.groups), [undefined, ["n", "g"], ["n", "g"], ["n"]])

  const inside = [box("a", ["g"]), box("b", ["g"]), box("c", ["g"])]
  const nested = group(inside, picked("a", "c"), "n")
  assert.deepEqual(ids(nested), ["b", "a", "c"])
  assert.deepEqual(nested.map((element) => element.groups), [["g"], ["g", "n"], ["g", "n"]])
})

test("grouping needs two whole units", () => {
  const elements = [box("a", ["g"]), box("b", ["g"]), box("c")]
  assert.equal(canGroup(elements, picked("a", "b")), false)
  assert.equal(canGroup(elements, picked("c")), false)
  // a's group is only partly picked, at the level c is at.
  assert.equal(canGroup(elements, picked("a", "c")), false)
  assert.equal(canGroup(elements, picked("a", "b", "c")), true)
})

test("ungrouping takes apart the groups picked whole, and keeps those inside", () => {
  const elements = [box("a", ["g", "h"]), box("b", ["g", "h"]), box("c", ["g"]), box("d")]
  assert.equal(canUngroup(elements, picked("d")), false)
  assert.equal(canUngroup(elements, picked("c")), false)
  assert.equal(canUngroup(elements, picked("a", "b", "c", "d")), true)

  const parted = ungroup(elements, picked("a", "b", "c"))
  assert.deepEqual(parted.map((element) => element.groups), [["h"], ["h"], undefined, undefined])
})

test("to the front and the back, picked units keep their order", () => {
  const elements = [box("a"), box("b"), box("c"), box("d")]
  assert.deepEqual(ids(restack(elements, picked("a", "c"), "front")), ["b", "d", "a", "c"])
  assert.deepEqual(ids(restack(elements, picked("b", "d"), "back")), ["b", "d", "a", "c"])
})

test("a group moves as one block, among its siblings", () => {
  const elements = [box("a", ["g"]), box("b", ["g"]), box("c"), box("d")]
  assert.deepEqual(ids(restack(elements, picked("a", "b"), "front")), ["c", "d", "a", "b"])
  // Picked inside its group, an element moves only there.
  const inside = [box("a", ["g"]), box("b", ["g"]), box("c", ["g"]), box("d")]
  assert.deepEqual(ids(restack(inside, picked("a"), "front")), ["b", "c", "a", "d"])
  assert.equal(canRestack(inside, picked("c"), "front"), false)
  assert.equal(canRestack(inside, picked("c"), "back"), true)
})

test("forward goes past the nearest sibling it overlaps", () => {
  // b and c are elsewhere; d is over a.
  const elements = [box("a", [], 0), box("b", [], 100), box("c", [], 200), box("d", [], 0), box("e", [], 300)]
  assert.deepEqual(ids(restack(elements, picked("a"), "forward")), ["b", "c", "d", "a", "e"])
  // With nothing above to overlap, it goes to the top, where it looks the same.
  const apart = [box("a", [], 0), box("b", [], 100), box("c", [], 200)]
  assert.deepEqual(ids(restack(apart, picked("a"), "forward")), ["b", "c", "a"])
})

test("backward goes under the nearest sibling it overlaps", () => {
  const elements = [box("a", [], 300), box("b", [], 0), box("c", [], 100), box("d", [], 0)]
  assert.deepEqual(ids(restack(elements, picked("d"), "backward")), ["a", "d", "b", "c"])
})

test("forward never passes another unit picked", () => {
  const elements = [box("a", [], 0), box("b", [], 100), box("c", [], 0), box("d", [], 0)]
  // c goes past d first, and a past b and d, staying under c.
  assert.deepEqual(ids(restack(elements, picked("a", "c"), "forward")), ["b", "d", "a", "c"])
  assert.equal(canRestack(elements, picked("d"), "forward"), false)
  assert.equal(canRestack(elements, picked("a"), "backward"), false)
})

test("the editor stays inside the groups still there", () => {
  const elements = [box("a", ["g", "h"]), box("b", ["g", "h"])]
  assert.deepEqual(existingPath(elements, ["g", "h"]), ["g", "h"])
  assert.deepEqual(existingPath(elements, ["g", "x"]), ["g"])
  assert.deepEqual(existingPath(elements, ["x"]), [])
})

test("stretching a selection stretches shapes and moves text by its middle", () => {
  const from = {x: 0, y: 0, width: 100, height: 100}
  const to = {x: 0, y: 0, width: 200, height: 50}
  const shape = {type: "rectangle", x: 50, y: 50, width: 50, height: 50}
  const text = {type: "text", x: 40, y: 40, width: 20, height: 20}
  const arrow = {type: "arrow", x1: 0, y1: 0, x2: 100, y2: 100, points: [{x: 50, y: 100}]}

  assert.deepEqual(scaleElement(shape, from, to), {x: 100, y: 25, width: 100, height: 25})
  assert.deepEqual(scaleElement(text, from, to), {x: 90, y: 15, width: 20})
  assert.deepEqual(scaleElement(arrow, from, to), {x1: 0, y1: 0, x2: 200, y2: 50, points: [{x: 100, y: 50}]})
})
