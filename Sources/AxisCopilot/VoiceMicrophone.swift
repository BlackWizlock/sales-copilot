import AVFoundation

/// Keep a live output render graph (muted) so Apple's voice-processing IO runs.
/// No captured microphone signal is played to the speakers.
enum VoiceMicrophone {
    static func makeEngine() throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        input.isVoiceProcessingAGCEnabled = false
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        let mixer = engine.mainMixerNode
        mixer.outputVolume = 0
        let inputFormat = input.outputFormat(forBus: 0)
        engine.connect(input, to: mixer, format: inputFormat)
        // VoiceProcessingIO requires the same client sample rate on both sides.
        // Hardware defaults may differ (e.g. microphone 48 kHz, speakers 44.1 kHz).
        // Keep the device settings unchanged; VPIO converts at its hardware boundary.
        guard let renderFormat = AVAudioFormat(standardFormatWithSampleRate: inputFormat.sampleRate,
                                               channels: engine.outputNode.inputFormat(forBus: 0).channelCount) else {
            throw NSError(domain: "AxisCopilot.Audio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L10n.string("Не удалось согласовать формат микрофона и динамиков.")])
        }
        engine.connect(mixer, to: engine.outputNode, format: renderFormat)
        return engine
    }
}
