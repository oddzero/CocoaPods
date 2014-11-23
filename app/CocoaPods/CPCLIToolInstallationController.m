#import "CPCLIToolInstallationController.h"

#import <libgen.h>
#import <Cocoa/Cocoa.h>
#import <SecurityFoundation/SFAuthorization.h>

NSString * const kCPRequestCLIToolInstallationAgainKey = @"CPRequestCLIToolInstallationAgain";
NSString * const kCPCLIToolInstalledToDestinationsKey = @"CPCLIToolInstalledToDestinations";

@interface CPCLIToolInstallationController ()
@property (strong) NSURL *destinationURL;
@end

@implementation CPCLIToolInstallationController

+ (instancetype)controllerWithSuggestedDestinationURL:(NSURL *)suggestedDestinationURL;
{
  return [[self alloc] initWithSuggestedDestinationURL:suggestedDestinationURL];
}

- (instancetype)initWithSuggestedDestinationURL:(NSURL *)suggestedDestinationURL;
{
  if ((self = [super init])) {
    _destinationURL = suggestedDestinationURL;
  }
  return self;
}

- (BOOL)installBinstubIfNecessary;
{
  if (access(self.destinationURL.fileSystemRepresentation, X_OK) == 0) {
    NSLog(@"Already installed binstub.");
    return NO;
  }

  if ([[NSUserDefaults standardUserDefaults] boolForKey:kCPRequestCLIToolInstallationAgainKey]) {
    NSLog(@"Asking the user to install the binstub again is prohibited.");
    return NO;
  }

  return [self installBinstub];
}

- (BOOL)installBinstub;
{
  BOOL installed = NO;
  if ([self runModalInstallationRequestAlert]) {
    NSLog(@"Try to install binstub to `%@`.", self.destinationURL.path);
    NSURL *destinationDirURL = [self.destinationURL URLByDeletingLastPathComponent];
    if (access(destinationDirURL.fileSystemRepresentation, W_OK) == 0) {
      installed = [self installBinstubToAccessibleDestination];
    } else {
      installed = [self installBinstubToPrivilegedDestination];
    }
    if (installed) {
      NSLog(@"Successfully wrote binstub to destination.");
      [self setDoNotRequestInstallationAgain];

      NSError *error = nil;
      NSData *bookmarkData = [self.destinationURL bookmarkDataWithOptions:NSURLBookmarkCreationPreferFileIDResolution|NSURLBookmarkCreationSuitableForBookmarkFile
                                           includingResourceValuesForKeys:nil
                                                            relativeToURL:nil
                                                                    error:&error];
      if (error) {
        NSLog(@"Unable to create bookmark data for binstub install destination (%@)", error);
      } else {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSArray *destinations = [defaults arrayForKey:kCPCLIToolInstalledToDestinationsKey];
        if (destinations) {
          for (NSData *destination in destinations) {
            error = nil;
            BOOL stale = NO;
            NSURL *bookmark = [NSURL URLByResolvingBookmarkData:destination
                                                        options:NSURLBookmarkResolutionWithoutUI|NSURLBookmarkResolutionWithoutMounting
                                                  relativeToURL:nil
                                            bookmarkDataIsStale:&stale
                                                          error:&error];
            if (error) {
              NSLog(@"Unable to resolve bookmark (%@)", error);
            } else {
              NSLog(@"EXISTING BOOKMARK: %@ (STALE: %@)", bookmark, (stale ? @"YES" : @"NO"));
            }
          }
          destinations = [destinations arrayByAddingObject:bookmarkData];
        } else {
          destinations = [NSArray arrayWithObject:bookmarkData];
        }
        [defaults setObject:destinations forKey:kCPCLIToolInstalledToDestinationsKey];
        [defaults synchronize];
      }
    }
  }
  return installed;
}

#pragma mark - Utility

// Never ask the user to automatically install again.
//
- (void)setDoNotRequestInstallationAgain;
{
  NSLog(@"Not going to automatically request binstub installation anymore.");
  [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kCPRequestCLIToolInstallationAgainKey];
  [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSURL *)binstubSourceURL;
{
  return [[NSBundle mainBundle] URLForResource:@"pod" withExtension:nil];
}

#pragma mark - User interaction (modal windows)

// Returns wether or not the user chose to perform the installation and, in case the user chose a
// different installation destination, the `destinationURL` is updated.
//
// In case the user chose to cancel the operation, this preference is stored and the user will not
// be automatically asked to install again on the next launch.
//
- (BOOL)runModalInstallationRequestAlert;
{
  NSString *destinationFilename = self.destinationURL.lastPathComponent;
  NSURL *destinationDirURL = [self.destinationURL URLByDeletingLastPathComponent];

  NSAlert *alert = [NSAlert new];
  alert.alertStyle = NSInformationalAlertStyle;
  alert.messageText = NSLocalizedString(@"INSTALL_CLI_MESSAGE_TEXT", nil);
  NSString *formatString = NSLocalizedString(@"INSTALL_CLI_INFORMATIVE_TEXT", nil);
  alert.informativeText = [NSString stringWithFormat:formatString, destinationFilename];
  formatString = NSLocalizedString(@"INSTALL_CLI", nil);
  [alert addButtonWithTitle:[NSString stringWithFormat:formatString, destinationDirURL.path]];
  [alert addButtonWithTitle:NSLocalizedString(@"INSTALL_CLI_ALTERNATE_DESTINATION", nil)];
  [alert addButtonWithTitle:NSLocalizedString(@"INSTALL_CLI_CANCEL", nil)];

  switch ([alert runModal]) {
    case NSAlertSecondButtonReturn:
      destinationDirURL = [self runModalDestinationOpenPanel:destinationDirURL];
      if (destinationDirURL == nil) {
        [self setDoNotRequestInstallationAgain];
        return NO;
      }
      break;
    case NSAlertThirdButtonReturn:
      [self setDoNotRequestInstallationAgain];
      return NO;
  }

  self.destinationURL = [destinationDirURL URLByAppendingPathComponent:destinationFilename];
  return YES;
}

// Allows the user to choose a different destination than the suggested destination.
//
// Returns either the `suggestedDirectoryURL`, a newly selected destination, or nil in case the user
// chose to cancel.
//
- (NSURL *)runModalDestinationOpenPanel:(NSURL *)suggestedDirectoryURL;
{
  NSOpenPanel *openPanel = [NSOpenPanel openPanel];
  openPanel.canChooseFiles = NO;
  openPanel.canChooseDirectories = YES;
  openPanel.canCreateDirectories = YES;
  openPanel.showsHiddenFiles = YES;
  openPanel.resolvesAliases = YES;
  openPanel.allowsMultipleSelection = NO;
  openPanel.directoryURL = suggestedDirectoryURL;
  if ([openPanel runModal] == NSFileHandlingPanelCancelButton) {
    return nil;
  }
  return openPanel.URLs[0];
}

#pragma mark - Binstub installation

// This simply performs a copy operation of the binstub to the destination without asking the user
// for authorization.
//
// Returns whether or not it succeeded.
//
- (BOOL)installBinstubToAccessibleDestination;
{
  NSError *error = nil;
  NSURL *sourceURL = self.binstubSourceURL;
  BOOL succeeded = [[NSFileManager defaultManager] copyItemAtURL:sourceURL
                                                           toURL:self.destinationURL
                                                           error:&error];
  if (error) {
    NSLog(@"Failed to copy source `%@` (%@)", sourceURL.path, error);
  }
  return succeeded;
}

// Tries to install the binstub to `destinationURL` by asking the user for authorization to write to
// the destination first.
//
// Because the user might have selected an alternate destination, and persisting that location leads
// to more complex rules about when to request for installation again, we configure the application to
// never again request for installation once succeeded.
//
// Do *not* store this earlier, because authorization or writing might fail before it's succeeded in
// which case the user should be requested for installation again on the next launch.
//
// Returns whether or not it succeeded.
//
- (BOOL)installBinstubToPrivilegedDestination;
{
  const char *destination_path = self.destinationURL.fileSystemRepresentation;

  // Configure requested authorization.
  char name[1024];
  sprintf(name, "sys.openfile.readwritecreate.%s", destination_path);
  AuthorizationFlags flags = kAuthorizationFlagInteractionAllowed |
                             kAuthorizationFlagExtendRights |
                             kAuthorizationFlagPreAuthorize;

  // Request the user for authorization.
  NSError *error = nil;
  SFAuthorization *authorization = [SFAuthorization authorization];
  if (![authorization obtainWithRight:name flags:flags error:&error]) {
    NSLog(@"Did not authorize.");
    return NO;
  }

  // Serialize the AuthorizationRef so it can be passed to the `authopen` tool.
  AuthorizationRef authorizationRef = [authorization authorizationRef];
  AuthorizationExternalForm serializedRef;
  OSStatus serialized = AuthorizationMakeExternalForm(authorizationRef, &serializedRef);
  if (serialized != errAuthorizationSuccess) {
    NSLog(@"Failed to serialize AuthorizationRef (%d)", serialized);
    return NO;
  }

  // Create a pipe through the `authopen` tool that allows file creation and
  // writing to the destination and also marks the file as being executable.
  char command[1024];
  sprintf(command, "/usr/libexec/authopen -extauth -c -m 0755 -w %s", destination_path);
  errno = 0;
  BOOL succeeded = NO;
  FILE *destination_pipe = popen(command, "w");
  if (destination_pipe == NULL) {
    NSLog(@"Failed to open pipe to `authopen` (%d - %s)", errno, strerror(errno));
  } else {
    // First send the pre-authorized and serialized AuthorizationRef so that the
    // `authopen` tool does not need to request authorization from the user,
    // which would lead to the user seeing an authorization dialog from
    // `authopen` instead of this app.
    fwrite(&serializedRef, sizeof(serializedRef), 1, destination_pipe);
    fflush(destination_pipe);
    // Now write the actual file data.
    NSURL *sourceURL = self.binstubSourceURL;
    FILE *source_file = fopen(sourceURL.fileSystemRepresentation, "r");
    if (source_file == NULL) {
      NSLog(@"Failed to open source `%@` (%d - %s)", sourceURL.path, errno, strerror(errno));
    } else {
      int c;
      while ((c = fgetc(source_file)) != EOF) {
        fwrite(&c, 1, 1, destination_pipe);
      }
      fclose(source_file);
      succeeded = YES;
    }
    pclose(destination_pipe);
  }
  return succeeded;
}

@end
