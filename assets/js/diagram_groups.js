// Groups and the drawing order.
//
// What is on top is decided by the order of the diagram's elements: a later
// one covers an earlier one. A group is a set of elements picked, moved and
// stacked as one. Each member lists the groups it is in, outermost first, in
// `groups`; an element in no group has none. Two premises hold, and
// `tidyGroups` restores them on whatever comes in:
//
//   * groups nest: every member of a group lists the same groups before it,
//     so two groups are either one inside the other or apart;
//   * a group's members are next to each other in the order, so the order
//     reads as a tree: units side by side, a group being a unit made of
//     units.
//
// Changes of order move units among their siblings, the other units of the
// same group (or of the diagram, outside any), so both go on holding. The
// same rules are kept on the server, in `MWTClient.Diagrams.Diagram`.

import {unionBounds} from "./diagram_geometry.js"

export const groupsOf = (element) => (Array.isArray(element.groups) ? element.groups : [])

// The groups two lists start with alike.
export function commonPath(a, b) {
  let length = 0
  while (length < a.length && length < b.length && a[length] === b[length]) length++
  return a.slice(0, length)
}

export const startsWith = (groups, path) => path.every((group, index) => groups[index] === group)

export const membersOf = (elements, group) =>
  elements.filter((element) => groupsOf(element).includes(group))

// What is picked along with `element` inside the groups of `path`, which it
// is in: the group it is in just inside them, or itself alone.
export function unitAt(elements, element, path) {
  const group = groupsOf(element)[path.length]
  return group === undefined ? [element] : membersOf(elements, group)
}

// The groups every member of which is among the `picked` ids.
export function wholeGroups(elements, picked) {
  const counts = new Map()
  for (const element of elements) {
    for (const group of groupsOf(element)) {
      const count = counts.get(group) ?? {all: 0, picked: 0}
      count.all++
      if (picked.has(element.id)) count.picked++
      counts.set(group, count)
    }
  }
  return new Set([...counts].filter(([, count]) => count.all === count.picked).map(([group]) => group))
}

// The groups the picked elements are all inside, short of any they make up
// whole: the level their units sit at. A whole group picked is a unit there,
// not a place to be inside.
export function selectionLevel(elements, picked) {
  const chosen = elements.filter((element) => picked.has(element.id))
  if (chosen.length === 0) return []

  let path = chosen.map(groupsOf).reduce(commonPath)
  const whole = wholeGroups(elements, picked)
  while (path.length && whole.has(path[path.length - 1])) path = path.slice(0, -1)
  return path
}

// The picked elements as units of their level, each the group it is in
// just inside that level, or itself, and whether all of it is picked.
export function selectionUnits(elements, picked) {
  const level = selectionLevel(elements, picked)
  const whole = wholeGroups(elements, picked)
  const units = new Map()

  for (const element of elements) {
    if (!picked.has(element.id)) continue
    const group = groupsOf(element)[level.length]
    const key = group ?? element
    if (!units.has(key)) units.set(key, {group, members: [], whole: group === undefined || whole.has(group)})
    units.get(key).members.push(element)
  }
  return {level, units: [...units.values()]}
}

// The longest start of `path` the diagram still has groups at.
export function existingPath(elements, path) {
  for (let length = path.length; length > 0; length--) {
    const start = path.slice(0, length)
    if (elements.some((element) => startsWith(groupsOf(element), start))) return start
  }
  return []
}

// Restores both premises, and drops groups left with one member. A group
// listed after other groups than its first member lists before it is
// dropped from that element, and every group after it. The members of each
// group are gathered where the topmost of them is. Changes the elements'
// lists in place, and gives the elements in their new order.
export function tidyGroups(elements) {
  const paths = new Map()
  for (const element of elements) {
    const kept = []
    for (const group of groupsOf(element)) {
      if (kept.includes(group)) break
      const before = JSON.stringify(kept)
      if (paths.has(group) && paths.get(group) !== before) break
      paths.set(group, before)
      kept.push(group)
    }
    setGroups(element, kept)
  }

  const counts = new Map()
  for (const element of elements) {
    for (const group of groupsOf(element)) counts.set(group, (counts.get(group) ?? 0) + 1)
  }
  // The groups inside a group of one have one member at most too, so what
  // is left of each list is a start of it, and still nests.
  for (const element of elements) {
    setGroups(element, groupsOf(element).filter((group) => counts.get(group) > 1))
  }

  return gather(elements, 0)
}

export function setGroups(element, groups) {
  if (groups.length) element.groups = groups
  else delete element.groups
}

function gather(elements, depth) {
  const units = new Map()
  elements.forEach((element, index) => {
    const group = groupsOf(element)[depth]
    const key = group ?? element
    if (!units.has(key)) units.set(key, {group, members: []})
    const unit = units.get(key)
    unit.members.push(element)
    unit.last = index
  })

  return [...units.values()]
    .sort((a, b) => a.last - b.last)
    .flatMap((unit) => (unit.group === undefined ? unit.members : gather(unit.members, depth + 1)))
}

// The units side by side at `depth`, in order, each the group there with
// its members or an element alone; relies on each group's members being
// next to each other.
export function unitsAt(elements, depth) {
  const list = []
  for (const element of elements) {
    const group = groupsOf(element)[depth]
    const last = list[list.length - 1]
    if (group !== undefined && last?.group === group) last.members.push(element)
    else list.push({group, members: [element]})
  }
  return list
}

// Groups the picked elements, which must be two units or more, each picked
// whole, at their level. The new group goes inside the level, around them,
// and its members are gathered where the topmost of them is.
export function canGroup(elements, picked) {
  const {units} = selectionUnits(elements, picked)
  return units.length > 1 && units.every((unit) => unit.whole)
}

export function group(elements, picked, id) {
  if (!canGroup(elements, picked)) return elements

  const level = selectionLevel(elements, picked)
  for (const element of elements) {
    if (!picked.has(element.id)) continue
    const groups = groupsOf(element)
    setGroups(element, [...level, id, ...groups.slice(level.length)])
  }
  return tidyGroups(elements)
}

// Takes apart the groups picked whole at the selection's level; what was
// inside them stays grouped as it was.
export function canUngroup(elements, picked) {
  return selectionUnits(elements, picked).units.some((unit) => unit.group !== undefined && unit.whole)
}

export function ungroup(elements, picked) {
  const {level, units} = selectionUnits(elements, picked)
  const parted = new Set(units.filter((unit) => unit.group !== undefined && unit.whole).map((unit) => unit.group))

  for (const element of elements) {
    const groups = groupsOf(element)
    if (picked.has(element.id) && parted.has(groups[level.length])) {
      setGroups(element, groups.filter((_, index) => index !== level.length))
    }
  }
  return tidyGroups(elements)
}

// Moving in the drawing order. Each unit picked whole moves among its
// siblings; one picked in part stays, and its own units move inside it.
// Units picked keep their order among themselves.
//
//   * front and back: above or below all their siblings;
//   * forward and backward: past the nearest sibling they overlap, so each
//     step shows, or to the end of the way when none does. They never pass
//     another unit picked.
export function restack(elements, picked, how) {
  return arrange(elements, 0, picked, STEPS[how])
}

// Whether `how` would change anything.
export function canRestack(elements, picked, how) {
  const order = restack(elements, picked, how)
  return order.some((element, index) => element !== elements[index])
}

function arrange(elements, depth, picked, step) {
  const marked = unitsAt(elements, depth).map((unit) => {
    const count = unit.members.filter((member) => picked.has(member.id)).length
    return {...unit, picked: count > 0 && count === unit.members.length, partly: count > 0 && count < unit.members.length}
  })
  return step(marked).flatMap((unit) =>
    unit.partly ? arrange(unit.members, depth + 1, picked, step) : unit.members)
}

const STEPS = {
  front: (list) => [...list.filter((unit) => !unit.picked), ...list.filter((unit) => unit.picked)],
  back: (list) => [...list.filter((unit) => unit.picked), ...list.filter((unit) => !unit.picked)],
  forward: (list) => stepPast(list),
  backward: (list) => stepPast([...list].reverse()).reverse(),
}

// Moves each picked unit up the list, the topmost first, past the
// unpicked units above it up to the first it overlaps, or to the last of
// them when it overlaps none.
function stepPast(list) {
  const order = [...list]
  for (let index = order.length - 2; index >= 0; index--) {
    if (!order[index].picked) continue

    let target = index
    for (let above = index + 1; above < order.length && !order[above].picked; above++) {
      target = above
      if (overlap(order[index], order[above])) break
    }
    if (target === index) continue

    const [unit] = order.splice(index, 1)
    order.splice(target, 0, unit)
  }
  return order
}

function overlap(a, b) {
  const one = unionBounds(a.members)
  const other = unionBounds(b.members)
  return one.x <= other.x + other.width && other.x <= one.x + one.width &&
    one.y <= other.y + other.height && other.y <= one.y + one.height
}
