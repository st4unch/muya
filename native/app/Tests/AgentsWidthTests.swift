// Unit tests of the agents column's width rules (Sources/Logic/AgentsWidth.swift).

import Foundation

func runAgentsWidthTests() {
    test("agents width: fresh launch gets the size-class default at 1120, 1440 and 1913") {
        check(AgentsWidth.restore(saved: nil, window: 1120) == 264, "1120")
        check(AgentsWidth.restore(saved: nil, window: 1440) == 296, "1440")
        check(AgentsWidth.restore(saved: nil, window: 1913) == 296, "1913")
    }
    test("agents width: a stale huge saved width is clamped to bounds and to a third of the window") {
        check(AgentsWidth.restore(saved: 650, window: 1913) == 480, "1913 -> 480 (32% = 612, capped at 480)")
        check(AgentsWidth.restore(saved: 480, window: 1120) == 358, "1120: 32% of the window")
        check(AgentsWidth.restore(saved: 480, window: 1440) == 460, "1440: 32% of the window")
        check(AgentsWidth.restore(saved: 100, window: 1440) == 220, "min")
    }
    test("agents width: a saved width inside the bounds is kept; tiny windows never go under the minimum") {
        check(AgentsWidth.restore(saved: 300, window: 1440) == 300, "kept")
        check(AgentsWidth.restore(saved: 400, window: 600) == 220, "600 wide: minimum wins")
        check(AgentsWidth.restore(saved: .nan, window: 1440) == 296, "NaN -> default")
        for w in [800.0, 1120, 1440, 1913, 2560] { check(AgentsWidth.upperBound(window: w) / w <= 0.32 + 0.0001 || AgentsWidth.upperBound(window: w) == 220, "fraction at \(w)") }
    }
}
