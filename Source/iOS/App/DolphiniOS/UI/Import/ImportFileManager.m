// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "ImportFileManager.h"

NSString* const DOLImportFileFinishedNotification = @"DOLImportFileFinishedNotification";

#import "Swift.h"

#import "GameFileCacheManager.h"
#import "LocalizationUtil.h"
#import "MainSceneCoordinator.h"

@implementation ImportFileManager {
  UIWindow* _window;
}

+ (ImportFileManager*)shared {
  static ImportFileManager* sharedInstance = nil;
  static dispatch_once_t onceToken;

  dispatch_once(&onceToken, ^{
    sharedInstance = [[self alloc] init];
  });

  return sharedInstance;
}

- (void)showWindowOnScene:(UIWindowScene*)scene {
  self->_window = [[UIWindow alloc] initWithWindowScene:scene];
  self->_window.frame = [UIScreen mainScreen].bounds;
  self->_window.rootViewController = [[UIViewController alloc] init];
  self->_window.windowLevel = UIWindowLevelAlert;
  
  UIWindow* topWindow = scene.windows.lastObject;
  self->_window.windowLevel = topWindow.windowLevel + 1;
  
  [self->_window makeKeyAndVisible];
}

- (void)hideWindow {
  [self->_window setHidden:true];
  
  self->_window = nil;
}

// gc-emu: Iridia's own popup (IridiaAlert) with one OK button that runs `then`.
- (void)showMessageWithTitle:(NSString*)title text:(NSString*)text then:(void (^)(void))then {
  IridiaAlertButton* ok = [[IridiaAlertButton alloc] initWithTitle:DOLCoreLocalizedString(@"OK") role:IridiaAlertRoleNormal action:then];
  [IridiaAlert showWithTitle:title message:text buttons:@[ok]];
}

- (void)presentViewControllerOnWindow:(UIViewController*)controller {
  [self->_window.rootViewController presentViewController:controller animated:true completion:nil];
}

- (void)importFileAtUrl:(NSURL*)url {
  UIWindowScene* mainScene = [MainSceneCoordinator shared].mainScene;
  
  if (mainScene == nil) {
    return;
  }
  
  [self showWindowOnScene:mainScene];
  
  if (![url startAccessingSecurityScopedResource]) {
    [self showMessageWithTitle:DOLCoreLocalizedString(@"Couldn't Add the Game")
                          text:DOLCoreLocalizedString(@"Iridia wasn't allowed to open that file. Try choosing it again.")
                          then:^{ [self hideWindow]; }];
    
    return;
  }
  
  void (^finish)(void) = ^void() {
    [url stopAccessingSecurityScopedResource];
    
    [self hideWindow];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:DOLImportFileFinishedNotification object:self userInfo:nil];
  };
  
  NSString* sourcePath = [url path];
  NSString* softwareFolder = [UserFolderUtil getSoftwareFolder];
  NSString* destinationPath = [softwareFolder stringByAppendingPathComponent:[sourcePath lastPathComponent]];

  NSFileManager* fileManager = [NSFileManager defaultManager];
  [DOLImportStaging removeStaleStagedImportsInFolder:softwareFolder];

  // Archive imports: extract on a background queue so the UI stays responsive.
  // Security-scoped access must remain active for the duration of extraction. The picked
  // archive is copied into a private temp dir first and is never modified.
  if ([DOLZipImportHelper isArchivePath:sourcePath]) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      DOLZipImportResult* result = [DOLZipImportHelper importPickedArchiveAtURL:url toFolder:softwareFolder];

      dispatch_async(dispatch_get_main_queue(), ^{
        if (result.importedCount > 0 || result.skippedExistingCount > 0) {
          NSString* snackbar = [DOLZipImportHelper snackbarTextForImportedCount:result.importedCount
                                                                     skippedCount:result.skippedExistingCount
                                                                archivesProcessed:1];
          [[NSNotificationCenter defaultCenter] postNotificationName:@"DOLShowSnackbar"
                                                              object:nil
                                                            userInfo:@{@"text": snackbar}];

          if (result.errorMessage != nil) {
            [self showMessageWithTitle:DOLCoreLocalizedString(@"Import") text:result.errorMessage then:finish];
          } else {
            finish();
          }
        } else if (result.errorMessage != nil) {
          [self showMessageWithTitle:DOLCoreLocalizedString(@"Couldn't Add the Game") text:result.errorMessage then:finish];
        } else {
          finish();
        }
      });
    });

    return;
  }

  if ([fileManager fileExistsAtPath:destinationPath]) {
    [self showMessageWithTitle:DOLCoreLocalizedString(@"Already Added")
                          text:DOLCoreLocalizedString(@"This game is already in your library.")
                          then:finish];
    
    return;
  }
  

  // Both actions run the file operation OFF the main thread (a 1.4 GB copy on main is a
  // watchdog-length hang), through DOLImportStaging (staged + size-verified, so an interrupted
  // copy never leaves a truncated file under the real name), and inside a background task so
  // leaving the app mid-copy does not suspend it half-written.
  void (^runFileOperation)(NSString*, BOOL (^)(NSError**)) = ^(NSString* failure, BOOL (^operation)(NSError**)) {
    UIBackgroundTaskIdentifier task = [DOLImportStaging beginBackgroundTask];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSError* error = nil;
      const BOOL ok = operation(&error);
      dispatch_async(dispatch_get_main_queue(), ^{
        [DOLImportStaging endBackgroundTask:task];
        if (!ok) {
          [self showMessageWithTitle:DOLCoreLocalizedString(@"Couldn't Add the Game")
                                text:[NSString stringWithFormat:@"%@\n\n%@", failure, error.localizedDescription]
                                then:finish];
        } else {
          [LibraryAddedDateStoreBridge recordPath:destinationPath];
          finish();
        }
      });
    });
  };

  IridiaAlertButton* copy = [[IridiaAlertButton alloc] initWithTitle:DOLCoreLocalizedString(@"Copy") role:IridiaAlertRoleNormal action:^{
    runFileOperation(DOLCoreLocalizedString(@"Iridia couldn't copy the game."), ^BOOL(NSError** error) {
      return [DOLImportStaging stagedCopyFromPath:sourcePath toPath:destinationPath error:error];
    });
  }];
  IridiaAlertButton* move = [[IridiaAlertButton alloc] initWithTitle:DOLCoreLocalizedString(@"Move") role:IridiaAlertRoleNormal action:^{
    runFileOperation(DOLCoreLocalizedString(@"Iridia couldn't move the game."), ^BOOL(NSError** error) {
      return [DOLImportStaging stagedMoveFromPath:sourcePath toPath:destinationPath error:error];
    });
  }];
  IridiaAlertButton* cancel = [[IridiaAlertButton alloc] initWithTitle:DOLCoreLocalizedString(@"Cancel") role:IridiaAlertRoleCancel action:finish];
  [IridiaAlert showWithTitle:DOLCoreLocalizedString(@"Import") message:nil buttons:@[copy, move, cancel]];
}

@end
