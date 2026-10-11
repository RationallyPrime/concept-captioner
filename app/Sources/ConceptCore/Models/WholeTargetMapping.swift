// App mapping policy; assignments serialize through the existing Job.Mapping contract.

public extension TargetConcept {
    /// Style and motion apply to the complete target; the other categories need a confirmed locator.
    var requiresLocator: Bool {
        wholeTargetLocator == nil
    }

    var wholeTargetLocator: String? {
        switch self {
        case .style: "the visual style of the entire image or clip"
        case .motion: "the defining movement throughout the entire image or clip"
        default: nil
        }
    }
}

public extension Job {
    var requiresLocatorMapping: Bool {
        concepts.contains { $0.targetConcept.requiresLocator }
    }

    /// Automatic whole-target assignments use the ordinary shared mapping, including in mixed jobs.
    var wholeTargetMapping: Mapping {
        Mapping(concepts.compactMap { concept in
            concept.targetConcept.wholeTargetLocator.map { (concept.trigger, $0) }
        })
    }

    /// Preserve the existing nil marker until a locator job is confirmed. Whole-target assignments
    /// are merged when confirmed; a job with only style/motion needs no separate confirmation.
    func mappingIncludingWholeTargets(_ mapping: Mapping?) -> Mapping? {
        guard mapping != nil || !requiresLocatorMapping else { return nil }
        var result = mapping ?? [:]
        for (trigger, locator) in wholeTargetMapping {
            result[trigger] = locator
        }
        return result.isEmpty ? nil : result
    }
}
