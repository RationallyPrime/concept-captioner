import ConceptCore

extension TargetConcept {
    static let beginnerChoices: [TargetConcept] = [.facialIdentity, .object, .characterDesign, .style, .motion]

    var title: String {
        switch self {
        case .facialIdentity: "Person"
        case .fullIdentity: "Whole-person identity"
        case .object: "Object"
        case .characterDesign: "Character"
        case .style: "Visual style"
        case .motion: "Motion or activity"
        case .custom: "Custom concept"
        }
    }

    var question: String {
        switch self {
        case .facialIdentity, .fullIdentity: "Who should the model be able to portray?"
        case .object: "Which object should the model be able to generate?"
        case .characterDesign: "Which character design should the model learn?"
        case .style: "Which visual style should the model learn?"
        case .motion: "Which motion or activity should the model learn?"
        case .custom: "What single concept should the model learn?"
        }
    }

    var example: String {
        switch self {
        case .facialIdentity: "The person's facial identity"
        case .fullIdentity: "The person's face and physique"
        case .object: "The distinctive design of this ceramic mug"
        case .characterDesign: "The appearance of this illustrated character, including its costume"
        case .style: "The brushwork, palette and texture shared by these paintings"
        case .motion: "The movement pattern of a person doing this dance"
        case .custom: "Describe the concept shown in your training data"
        }
    }

    var captionExplanation: String {
        switch self {
        case .facialIdentity, .fullIdentity:
            "Captions use the trigger for this identity and describe the visible details outside it: "
                + "clothing, expression, pose, surroundings and light."
        case .object, .characterDesign:
            "Captions use the trigger for the object's or character's defining design. "
                + "They describe its placement, pose or use and the surrounding scene."
        case .style:
            "Captions describe what each image shows. The trigger stands for the style, "
                + "so the captions leave out the stylistic qualities you want the model to learn."
        case .motion:
            "Captions use the trigger for the movement pattern and describe the performer and scene. "
                + "Use video clips that show the motion; a still image cannot demonstrate how it unfolds."
        case .custom:
            "Captions use the trigger for the stated concept and describe the observable details outside it."
        }
    }

    var locatorHint: String {
        switch self {
        case .facialIdentity, .fullIdentity: "For example: the person on the left wearing a blue shirt"
        case .object, .characterDesign: "For example: the red ceramic mug in the foreground"
        case .style: "The visual style of the entire image or clip"
        case .motion: "Identify the performer and the part of the clip showing the target motion"
        case .custom: "Identify where this concept appears in the image or clip"
        }
    }
}
