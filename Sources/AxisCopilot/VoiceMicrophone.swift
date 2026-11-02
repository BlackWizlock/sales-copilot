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
        engine.connect(input, to: mixer, format: input.outputFormat(forBus: 0))
        return engine
    }
}
