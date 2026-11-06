#pragma once

// Iridia Wii U app: iOS audio output (RemoteIO). Takes the Cubeb slot in IAudioAPI, so the settings' audio API
// "Cubeb" with device "default" selects it.
#include "IAudioAPI.h"
#include "IridiaStretch.h"
#include <AudioToolbox/AudioToolbox.h>

class IOSAudioAPI : public IAudioAPI
{
public:
	class IOSDeviceDescription : public DeviceDescription
	{
	public:
		IOSDeviceDescription() : DeviceDescription(L"Speaker") {}
		std::wstring GetIdentifier() const override { return L"default"; }
	};

	IOSAudioAPI(uint32 samplerate, uint32 channels, uint32 samples_per_block, uint32 bits_per_sample);
	~IOSAudioAPI();

	AudioAPI GetType() const override { return Cubeb; }
	bool NeedAdditionalBlocks() const override;
	bool FeedBlock(sint16* data) override;
	bool Play() override;
	bool Stop() override;
	void SetVolume(sint32 volume) override;

	static std::vector<DeviceDescriptionPtr> GetDevices();

	OSStatus Render(AudioBufferList* data, uint32 frames);

private:
	AudioComponentInstance m_unit = nullptr;
	bool m_playing = false;
	std::atomic<float> m_volumeScale{1.0f};
	mutable std::mutex m_mutex;
	std::vector<uint8> m_buffer;
	std::unique_ptr<IridiaStretch> m_stretch; // IRIDIA_AUDIO_STRETCH=1
};
