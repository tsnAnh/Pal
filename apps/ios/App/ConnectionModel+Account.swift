import PalChat

extension ConnectionModel {
    func forgetAccountData() async {
        surfaces.forgetAll()
        ChatImageDecoder.removeAll()
        await MediaPosterCache.shared.removeAll()
    }
}
