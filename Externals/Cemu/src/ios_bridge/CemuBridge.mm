// Iridia Wii U app: starts the Cemu core without its desktop UI (what CemuApp::OnInit and MainWindow::FileLoad
// do on the desktop, minus wxWidgets).
#import "ios_bridge/CemuBridge.h"
#import <Metal/MTLDeviceCertification.h>

#include "config/ActiveSettings.h"
#include "config/CemuConfig.h"
#include "config/LaunchSettings.h"
#include "config/NetworkSettings.h"
#include "Cafe/CafeSystem.h"
#include "Cafe/TitleList/TitleList.h"
#include "Cafe/Filesystem/FST/KeyCache.h"
#include "Cafe/HW/Latte/Core/Latte.h"
#include "Cafe/HW/Latte/Core/LatteOverlay.h"
#include "Cafe/HW/Latte/Core/IridiaPerf.h"
#include "Cafe/HW/Latte/Renderer/Metal/MetalRenderer.h"
#include "Cafe/OS/libs/vpad/IridiaExternalPad.h"
#include "Cemu/ncrypto/ncrypto.h"
#include "audio/IAudioAPI.h"
#include "WindowSystem.h"

#include <boost/algorithm/string.hpp>
#include <fstream>

void CemuCommonInit(); // main.cpp
std::string IridiaNoJitSelfCheck(); // NoJitCheckIOS.mm
extern std::string g_iridiaLastCoreError; // WindowSystemIOS.mm
extern std::atomic<bool> g_iridiaPaused; // PPCScheduler.cpp

@implementation CemuTitle
@end
@implementation CemuPerf
@end

static bool s_started = false;
static std::atomic<bool> s_gameEnded{false};

/// The core's callbacks to the app: the game ended by itself (exit, or a return to the system menu), or asked
/// for a new canvas (nothing to do, the app's layer stays).
class IridiaSystem : public CafeSystem::SystemImplementation
{
public:
	void CafeRecreateCanvas() override {}
	void CafePPCProcessExit() override { s_gameEnded = true; }
};
static IridiaSystem s_system;
static std::atomic<bool> s_running{false};

// Same as CemuApp::CreateDefaultMLCFiles.
static bool CreateDefaultMLCFiles(const fs::path& mlc)
{
	std::error_code ec;
	const fs::path directories[] = {
		mlc, mlc / "sys", mlc / "usr", mlc / "usr/title/00050000", mlc / "usr/title/0005000c", mlc / "usr/title/0005000e",
		mlc / "usr/save/00050010/1004a000/user/common/db", mlc / "usr/save/00050010/1004a100/user/common/db",
		mlc / "usr/save/00050010/1004a200/user/common/db", mlc / "sys/title/0005001b/1005c000/content"};
	for (auto& path : directories)
		if (!fs::exists(path, ec) && !fs::create_directories(path, ec))
			return false;
	try
	{
		const auto langDir = fs::path(mlc).append("sys/title/0005001b/1005c000/content");
		auto langFile = fs::path(langDir).append("language.txt");
		if (!fs::exists(langFile))
		{
			std::ofstream file(langFile);
			const char* langStrings[] = {"ja", "en", "fr", "de", "it", "es", "zh", "ko", "nl", "pt", "ru", "zh"};
			for (const char* lang : langStrings)
				file << fmt::format(R"("{}",)", lang) << std::endl;
		}
		auto countryFile = fs::path(langDir).append("country.txt");
		if (!fs::exists(countryFile))
		{
			std::ofstream file(countryFile);
			for (sint32 i = 0; i < NCrypto::GetCountryCount(); i++)
			{
				const char* countryCode = NCrypto::GetCountryAsString(i);
				if (boost::iequals(countryCode, "NN"))
					file << "NULL," << std::endl;
				else
					file << fmt::format(R"("{}",)", countryCode) << std::endl;
			}
		}
	}
	catch (const std::exception&)
	{
		return false;
	}
	return true;
}

static std::string FormatName(const TitleInfo& info)
{
	switch (info.GetFormat())
	{
	case TitleInfo::TitleDataFormat::HOST_FS: return "folder";
	case TitleInfo::TitleDataFormat::WUD: return "disc image";
	case TitleInfo::TitleDataFormat::WUHB: return "wuhb";
	case TitleInfo::TitleDataFormat::WIIU_ARCHIVE: return "wua";
	case TitleInfo::TitleDataFormat::NUS: return "nus";
	default: return "game";
	}
}

@implementation CemuBridge

+ (nullable NSString *)startWithUserDir:(NSString *)userDir gamesDir:(NSString *)gamesDir resourcesDir:(NSString *)resourcesDir
{
	if (s_started)
		return nil;
	// Interpreter only (no JIT on iOS), one host thread per emulated core, iPhone core placement
	// (core 1 + the busier of 0/2 on the two performance cores).
	setenv("IRIDIA_IPHONE_LAYOUT", "1", 0);
	setenv("IRIDIA_GPU_QOS", "utility", 0); // GPU thread may use a fast core when one is free (background QoS can be throttled on iOS)
	setenv("IRIDIA_QUANTUM", "100000", 0); // longer time slices: fewer thread switches
	char arg0[] = "Cemu";
	char arg1[] = "--force-multicore-interpreter";
	char* argv[] = {arg0, arg1, nullptr};
	LaunchSettings::HandleCommandline(2, argv);

	const fs::path user = _utf8ToPath(userDir.UTF8String);
	const fs::path data = _utf8ToPath(resourcesDir.UTF8String);
	std::set<fs::path> failedWriteAccess;
	ActiveSettings::SetPaths(false, data / "Cemu", user, user, user / "cache", data, failedWriteAccess);
	if (!failedWriteAccess.empty())
		return @"Can't write to the app's data folder.";

	std::error_code ec;
	fs::create_directories(ActiveSettings::GetConfigPath("controllerProfiles"), ec);
	GetConfigHandle().SetFilename(ActiveSettings::GetConfigPath("settings.xml").generic_wstring());
	if (fs::exists(ActiveSettings::GetConfigPath("settings.xml"), ec))
		GetConfigHandle().Load();
	NetworkConfig::LoadOnce();

	// Same graphics settings as the Mac study builds (Metal, draw-done sync on, async shader compile).
	auto& config = GetConfig();
	config.graphic_api = GraphicAPI::kMetal;
	config.game_paths.clear();
	config.game_paths.emplace_back(gamesDir.UTF8String);
	config.mlc_path = _pathToUtf8(user / "mlc01");
	config.audio_api = 3; // IAudioAPI::Cubeb slot = iOS RemoteIO output (audio/IOSAudioAPI.mm)
	config.tv_device = L"default";
	// Sound queued ahead, in 12 ms blocks: 6 (72 ms) rides through the short hitches that made 2 (24 ms, Cemu's
	// default) crackle on the phone.
	config.audio_delay = 6;
	if (config.tv_volume == 0)
		config.tv_volume = 50;

	GetConfigHandle().Save();

	if (!CreateDefaultMLCFiles(ActiveSettings::GetMlcPath()))
		return @"Can't create the console storage folder.";

	CafeSystem::SetImplementation(&s_system);
	ActiveSettings::Init();
	LatteOverlay_init();
	CemuCommonInit();
	s_started = true;
	return nil;
}

+ (NSArray<CemuTitle *> *)scanGames
{
	CafeTitleList::Refresh();
	CafeTitleList::WaitForMandatoryScan();
	while (CafeTitleList::IsScanning())
		std::this_thread::sleep_for(std::chrono::milliseconds(50));
	NSMutableArray<CemuTitle *> *out = [NSMutableArray array];
	auto list = CafeTitleList::AcquireInternalList();
	for (TitleInfo* info : list)
	{
		if (!info || !info->IsValid())
			continue;
		if (info->GetTitleType() != TitleIdParser::TITLE_TYPE::BASE_TITLE)
			continue;
		CemuTitle *t = [CemuTitle new];
		std::string name = info->GetMetaTitleName();
		t.name = [NSString stringWithUTF8String:(name.empty() ? _pathToUtf8(info->GetPath().filename()) : name).c_str()];
		t.path = [NSString stringWithUTF8String:_pathToUtf8(info->GetPath()).c_str()];
		t.titleId = info->GetAppTitleId();
		t.version = info->GetAppTitleVersion();
		t.format = [NSString stringWithUTF8String:FormatName(*info).c_str()];
		[out addObject:t];
	}
	CafeTitleList::ReleaseInternalList();
	return out;
}

+ (void)reloadKeys
{
	if (s_running)
		return;
	KeyCache_Reload();
}

+ (nullable NSString *)launchTitle:(CemuTitle *)title layer:(CAMetalLayer *)layer width:(int)width height:(int)height
{
	if (s_running)
		return @"A game is already running.";
	const fs::path launchPath = _utf8ToPath(title.path.UTF8String);
	CafeSystem::PREPARE_STATUS_CODE r;
	std::string ext = _pathToUtf8(launchPath.extension());
	std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
	if (ext == ".rpx" || ext == ".elf")
	{
		// A standalone program (homebrew), not an installed title.
		r = CafeSystem::PrepareForegroundTitleFromStandaloneRPX(launchPath);
		if (r != CafeSystem::PREPARE_STATUS_CODE::SUCCESS)
			return @"This program couldn't be opened.";
		return [self startForegroundTitleOnLayer:layer width:width height:height];
	}
	TitleInfo launchTitle{launchPath};
	if (!launchTitle.IsValid())
	{
		if (launchTitle.GetInvalidReason() == TitleInfo::InvalidReason::NO_DISC_KEY)
			return @"This disc can't be read without its key. Put keys.txt with the game's disc key in the Wii U folder.";
		return @"This game can't be opened.";
	}
	CafeTitleList::AddTitleFromPath(launchPath);
	TitleId baseTitleId;
	if (!CafeTitleList::FindBaseTitleId(launchTitle.GetAppTitleId(), baseTitleId))
		return @"The game's base files weren't found.";
	r = CafeSystem::PrepareForegroundTitle(baseTitleId);
	if (r == CafeSystem::PREPARE_STATUS_CODE::UNABLE_TO_MOUNT)
		return @"The game couldn't be opened.";
	if (r != CafeSystem::PREPARE_STATUS_CODE::SUCCESS)
		return @"The game failed to start.";
	return [self startForegroundTitleOnLayer:layer width:width height:height];
}

/// Graphics, input and the emulated console for the prepared title.
+ (nullable NSString *)startForegroundTitleOnLayer:(CAMetalLayer *)layer width:(int)width height:(int)height
{
	auto& wi = WindowSystem::GetWindowInfo();
	const float scale = (float)layer.contentsScale;
	wi.width = width;
	wi.height = height;
	wi.phys_width = (int)(width * scale);
	wi.phys_height = (int)(height * scale);
	wi.dpi_scale = scale;
	wi.app_active = true;
	wi.window_main.backend = WindowSystem::WindowHandleInfo::Backend::Cocoa;
	wi.window_main.surface = (__bridge void*)layer;
	wi.canvas_main = wi.window_main;
	try
	{
		g_renderer = std::make_unique<MetalRenderer>();
		MetalRenderer::GetInstance()->InitializeLayer({width, height}, true);
	}
	catch (const std::exception& ex)
	{
		return [NSString stringWithFormat:@"Graphics couldn't start: %s", ex.what()];
	}
	g_iridiaExternalPad.active = true;
	s_running = true;
	s_gameEnded = false;
	g_iridiaPaused = false;
	CafeSystem::LaunchForegroundTitle();
	return nil;
}

+ (void)stopGame
{
	if (!s_running)
		return;
	g_iridiaPaused = false;
	g_iridiaExternalPad.active = false;
	g_iridiaExternalPad.lastReadTouch = 0;
	IridiaPadMotionReset(true);
	LatteGPUState.iridiaPadShowsTV = false;
	CafeSystem::ShutdownTitle();
	auto& wi = WindowSystem::GetWindowInfo();
	wi.pad_open = false;
	g_renderer.reset();
	wi.window_main.surface = nullptr;
	wi.canvas_main = wi.window_main;
	wi.window_pad.surface = nullptr;
	wi.canvas_pad = wi.window_pad;
	s_running = false;
}

+ (BOOL)hasGameEnded
{
	return s_gameEnded.load();
}

+ (void)setPaused:(BOOL)paused
{
	g_iridiaPaused = paused;
	if (g_tvAudio)
		g_tvAudio->SetVolume(paused ? 0 : GetConfig().tv_volume);
}

+ (BOOL)isPaused
{
	return g_iridiaPaused.load();
}

+ (void)resizeWidth:(int)width height:(int)height
{
	auto& wi = WindowSystem::GetWindowInfo();
	const double scale = wi.dpi_scale.load() > 0 ? wi.dpi_scale.load() : 1.0;
	wi.width = width;
	wi.height = height;
	wi.phys_width = (int)(width * scale);
	wi.phys_height = (int)(height * scale);
	if (s_running && g_renderer)
		MetalRenderer::GetInstance()->ResizeLayer({width, height}, true);
}

+ (void)setGamePadOnMainScreen:(BOOL)on
{
	setenv("IRIDIA_DRC_PRIMARY", on ? "1" : "0", 1); // read when a game starts
	LatteGPUState.isDRCPrimary = on;
}

+ (nullable NSString *)setGamePadLayer:(nullable CAMetalLayer *)layer width:(int)width height:(int)height
{
	auto& wi = WindowSystem::GetWindowInfo();
	if (!s_running || !g_renderer)
		return @"No game is running.";
	if (!layer)
	{
		wi.pad_open = false;
		MetalRenderer::GetInstance()->ShutdownLayer(false);
		return nil;
	}
	const float scale = (float)layer.contentsScale;
	wi.pad_width = width;
	wi.pad_height = height;
	wi.phys_pad_width = (int)(width * scale);
	wi.phys_pad_height = (int)(height * scale);
	wi.pad_dpi_scale = scale;
	wi.window_pad.backend = WindowSystem::WindowHandleInfo::Backend::Cocoa;
	wi.window_pad.surface = (__bridge void*)layer;
	wi.canvas_pad = wi.window_pad;
	try
	{
		MetalRenderer::GetInstance()->InitializeLayer({width, height}, false);
	}
	catch (const std::exception& ex)
	{
		return [NSString stringWithFormat:@"The GamePad screen couldn't start: %s", ex.what()];
	}
	wi.pad_open = true;
	return nil;
}

+ (void)resizeGamePadWidth:(int)width height:(int)height
{
	auto& wi = WindowSystem::GetWindowInfo();
	const double scale = wi.pad_dpi_scale.load() > 0 ? wi.pad_dpi_scale.load() : 1.0;
	wi.pad_width = width;
	wi.pad_height = height;
	wi.phys_pad_width = (int)(width * scale);
	wi.phys_pad_height = (int)(height * scale);
	if (s_running && g_renderer && wi.pad_open)
		MetalRenderer::GetInstance()->ResizeLayer({width, height}, false);
}

+ (void)setTouchDown:(BOOL)down x:(float)x y:(float)y
{
	g_iridiaExternalPad.touchX = x;
	g_iridiaExternalPad.touchY = y;
	g_iridiaExternalPad.touchDown = down;
}

+ (BOOL)lastGameTouchX:(float *)x y:(float *)y down:(BOOL *)down
{
	const uint32 raw = g_iridiaExternalPad.lastReadTouch.load();
	if (raw == 0)
		return NO;
	// the panel mapping in vpad.cpp, inverted: raw x = px * 3883 + 92, raw y = 4095 - py * 3694 - 254
	const float rx = (float)(raw & 0xFFFF), ry = (float)((raw >> 16) & 0x7FFF);
	*x = (rx - 92.0f) / 3883.0f * 854.0f;
	*y = (4095.0f - 254.0f - ry) / 3694.0f * 480.0f;
	*down = (raw & 0x80000000u) != 0;
	return YES;
}

+ (void)setGamePadLayerShowsTV:(BOOL)on
{
	LatteGPUState.iridiaPadShowsTV = on;
}

+ (void)addMotionSampleDt:(float)dt gyroX:(float)gx gyroY:(float)gy gyroZ:(float)gz
                     accX:(float)ax accY:(float)ay accZ:(float)az
{
	IridiaPadMotionSample(dt, gx, gy, gz, ax, ay, az);
}

+ (void)resetMotionOff:(BOOL)off
{
	IridiaPadMotionReset(off);
}

+ (BOOL)isRunning
{
	return s_running.load();
}

+ (void)setButtons:(uint32_t)buttons leftX:(float)lx leftY:(float)ly rightX:(float)rx rightY:(float)ry
{
	g_iridiaExternalPad.buttons = buttons;
	g_iridiaExternalPad.lx = lx;
	g_iridiaExternalPad.ly = ly;
	g_iridiaExternalPad.rx = rx;
	g_iridiaExternalPad.ry = ry;
}

+ (CemuPerf *)perf
{
	CemuPerf *p = [CemuPerf new];
	p.seq = g_iridiaPerf.seq.load();
	p.fps = g_iridiaPerf.fps.load();
	p.drawsPerFrame = g_iridiaPerf.drawsPerFrame.load();
	p.vsyncs = g_iridiaPerf.vsyncs.load();
	p.flips = g_iridiaPerf.flips.load();
	p.vsyncWaitMs = g_iridiaPerf.vsyncWaitMs.load();
	p.gpuWaitMs = g_iridiaPerf.gpuWaitMs.load();
	p.vblankLateMs = g_iridiaPerf.vblankLateMs.load();
	p.gameplaySeconds = g_iridiaPerf.gameplaySeconds.load();
	return p;
}

+ (NSString *)noJitSelfCheck
{
	return [NSString stringWithUTF8String:IridiaNoJitSelfCheck().c_str()];
}

+ (nullable NSString *)lastCoreError
{
	if (g_iridiaLastCoreError.empty())
		return nil;
	return [NSString stringWithUTF8String:g_iridiaLastCoreError.c_str()];
}

@end
