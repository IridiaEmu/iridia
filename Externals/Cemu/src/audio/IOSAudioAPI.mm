// Iridia Wii U app: audio output on iOS through a RemoteIO audio unit (cubeb's AudioUnit backend is macOS-only).
// Same buffering as CubebAPI: the emulator feeds 16-bit blocks, the render callback drains them.
#include "IOSAudioAPI.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

// Iridia diagnostics (IRIDIA_DIAG "audio" field): output callbacks that found too little sound queued (a gap)
extern std::atomic<uint32_t> g_iridiaAudioUnderruns, g_iridiaAudioCallbacks, g_iridiaAudioDropped; // IAudioAPI.cpp

static OSStatus RenderCallback(void* user, AudioUnitRenderActionFlags*, const AudioTimeStamp*, UInt32, UInt32 frames, AudioBufferList* data)
{
	return ((IOSAudioAPI*)user)->Render(data, frames);
}

OSStatus IOSAudioAPI::Render(AudioBufferList* data, uint32 frames)
{
	uint8* out = (uint8*)data->mBuffers[0].mData;
	const size_t size = std::min<size_t>((size_t)frames * m_channels * (m_bitsPerSample / 8), data->mBuffers[0].mDataByteSize);
	std::unique_lock lock(m_mutex);
	if (m_stretch)
	{
		if (!m_stretch->Render((sint16*)out, (uint32)(size / (m_channels * 2)), m_buffer))
			g_iridiaAudioUnderruns.fetch_add(1, std::memory_order_relaxed);
		lock.unlock();
		g_iridiaAudioCallbacks.fetch_add(1, std::memory_order_relaxed);
		const float vol = m_volumeScale.load(std::memory_order_relaxed);
		if (vol < 0.999f)
		{
			sint16* s = (sint16*)out;
			for (size_t i = 0; i < size / 2; i++)
				s[i] = (sint16)(s[i] * vol);
		}
		return noErr;
	}
	const size_t copied = std::min(m_buffer.size(), size);
	if (copied)
	{
		memcpy(out, m_buffer.data(), copied);
		m_buffer.erase(m_buffer.begin(), m_buffer.begin() + copied);
	}
	lock.unlock();
	if (copied != size)
	{
		memset(out + copied, 0, size - copied);
		g_iridiaAudioUnderruns.fetch_add(1, std::memory_order_relaxed);
	}
	g_iridiaAudioCallbacks.fetch_add(1, std::memory_order_relaxed);
	// volume
	const float vol = m_volumeScale.load(std::memory_order_relaxed);
	if (vol < 0.999f)
	{
		sint16* s = (sint16*)out;
		for (size_t i = 0; i < size / 2; i++)
			s[i] = (sint16)(s[i] * vol);
	}
	return noErr;
}

IOSAudioAPI::IOSAudioAPI(uint32 samplerate, uint32 channels, uint32 samples_per_block, uint32 bits_per_sample)
	: IAudioAPI(samplerate, channels, samples_per_block, bits_per_sample)
{
	m_buffer.reserve((size_t)m_bytesPerBlock * kBlockCount);
	if (IridiaStretchEnabled())
		m_stretch = std::make_unique<IridiaStretch>((int)channels);

	AVAudioSession* session = [AVAudioSession sharedInstance];
	[session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:AVAudioSessionCategoryOptionMixWithOthers error:nil];
	// small output chunks (10 ms): each callback takes less of the queue at once
	[session setPreferredIOBufferDuration:0.010 error:nil];
	[session setActive:YES error:nil];

	AudioComponentDescription desc{};
	desc.componentType = kAudioUnitType_Output;
	desc.componentSubType = kAudioUnitSubType_RemoteIO;
	desc.componentManufacturer = kAudioUnitManufacturer_Apple;
	AudioComponent comp = AudioComponentFindNext(nullptr, &desc);
	if (!comp || AudioComponentInstanceNew(comp, &m_unit) != noErr)
		throw std::runtime_error("can't create iOS audio unit");

	AudioStreamBasicDescription fmt{};
	fmt.mSampleRate = samplerate;
	fmt.mFormatID = kAudioFormatLinearPCM;
	fmt.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
	fmt.mChannelsPerFrame = channels;
	fmt.mBitsPerChannel = bits_per_sample;
	fmt.mBytesPerFrame = channels * (bits_per_sample / 8);
	fmt.mFramesPerPacket = 1;
	fmt.mBytesPerPacket = fmt.mBytesPerFrame;
	AudioUnitSetProperty(m_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));

	AURenderCallbackStruct cb{RenderCallback, this};
	AudioUnitSetProperty(m_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof(cb));
	if (AudioUnitInitialize(m_unit) != noErr)
		throw std::runtime_error("can't start iOS audio unit");
}

IOSAudioAPI::~IOSAudioAPI()
{
	Stop();
	if (m_unit)
	{
		AudioUnitUninitialize(m_unit);
		AudioComponentInstanceDispose(m_unit);
	}
}

bool IOSAudioAPI::NeedAdditionalBlocks() const
{
	std::unique_lock lock(m_mutex);
	return m_buffer.size() < GetAudioDelay() * m_bytesPerBlock;
}

bool IOSAudioAPI::FeedBlock(sint16* data)
{
	std::unique_lock lock(m_mutex);
	if (m_buffer.capacity() <= m_buffer.size() + m_bytesPerBlock)
	{
		g_iridiaAudioDropped.fetch_add(1, std::memory_order_relaxed);
		return false;
	}
	m_buffer.insert(m_buffer.end(), (uint8*)data, (uint8*)data + m_bytesPerBlock);
	return true;
}

bool IOSAudioAPI::Play()
{
	if (m_playing)
		return true;
	m_playing = AudioOutputUnitStart(m_unit) == noErr;
	return m_playing;
}

bool IOSAudioAPI::Stop()
{
	if (!m_playing)
		return true;
	m_playing = !(AudioOutputUnitStop(m_unit) == noErr);
	return !m_playing;
}

void IOSAudioAPI::SetVolume(sint32 volume)
{
	IAudioAPI::SetVolume(volume);
	m_volumeScale = std::clamp(volume / 100.0f, 0.0f, 1.0f);
}

std::vector<IAudioAPI::DeviceDescriptionPtr> IOSAudioAPI::GetDevices()
{
	return {std::make_shared<IOSDeviceDescription>()};
}
