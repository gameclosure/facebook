#import "FacebookPlugin.h"
#import "platform/log.h"
#import <FacebookSDK/FacebookSDK.h>

@implementation FacebookPlugin

static FBFrictionlessRecipientCache * friendCache = NULL;

// -----------------------------------------------------------------------------
// EXPOSED PLUGIN METHODS
// -----------------------------------------------------------------------------

- (NSString *) facebookInit:(NSDictionary *)opts {
    NSLOG(@"{facebook} opts %@", opts);

    // lowercase appId param matches the JS init interface
    NSString *appID = [opts objectForKey:@"appId"];
    NSString *displayName = [opts objectForKey:@"displayName"];

    [FBSettings setDefaultAppID:appID];
    [FBSettings setDefaultDisplayName:displayName];
    NSNumber * frictionlessRequests = [opts objectForKey:@"frictionlessRequests"];

    NSLOG(@"{facebook} SET DEFAULTS %@ %@", appID, displayName);

    [FBSession openActiveSessionWithReadPermissions:nil
      allowLoginUI:NO
      completionHandler:^(FBSession *session, FBSessionState state, NSError * error) {
        if (frictionlessRequests != nil && [frictionlessRequests boolValue] == YES) {
          friendCache = [[FBFrictionlessRecipientCache alloc] init];
          [friendCache prefetchAndCacheForSession:session];
        }

        [self onSessionStateChanged:session state:state error:error];
      }];



    return @"{\"status\": \"ok\"}";
}

- (void) login:(NSDictionary *)opts withRequestId:(NSNumber *)requestId {
  BOOL permissionsAllowed = YES;
  NSString *permissionsErrorMessage = @"";
  NSArray *permissions = [(NSString *)opts[@"scope"] componentsSeparatedByString:@","];

  // save the callbackId for the login callback
  self.loginRequestId = requestId;

  // Check if the session is open or not
  if (FBSession.activeSession.isOpen) {
    // Reauthorize if the session is already open.
    // In this instance we can ask for publish type
    // or read type only if taking advantage of iOS6.
    // To mix both, we'll use deprecated methods
    BOOL publishPermissionFound = NO;
    BOOL readPermissionFound = NO;
    for (NSString *p in permissions) {
      if ([self isPublishPermission:p]) {
        publishPermissionFound = YES;
      } else {
        readPermissionFound = YES;
      }

      // If we've found one of each we can stop looking.
      if (publishPermissionFound && readPermissionFound) {
        break;
      }
    }

    if (publishPermissionFound && readPermissionFound) {
      // Mix of permissions, not allowed
      permissionsAllowed = NO;
      permissionsErrorMessage = @"Your app can't ask for both read and write permissions.";
    } else if (publishPermissionFound) {
      // Only publish permissions
      self.loginRequestId = requestId;
      [FBSession.activeSession
        requestNewPublishPermissions:permissions
        defaultAudience:FBSessionDefaultAudienceFriends
        completionHandler:^(FBSession *session, NSError *error) {
          [self onSessionStateChanged:session state:session.state error:error];
        }];
    } else {
      // Only read permissions
      self.loginRequestId = requestId;
      [FBSession.activeSession
        requestNewReadPermissions:permissions
        completionHandler:^(FBSession *session, NSError *error) {
          [self onSessionStateChanged:session
            state:session.state
            error:error];
        }];
    }
  } else {
    // Initial log in, can only ask to read
    // type permissions
    if ([self areAllPermissionsReadPermissions:permissions]) {
      self.loginRequestId = requestId;
      NSLOG(@"{facebook} requesting initial login");
      [FBSession
        openActiveSessionWithReadPermissions:permissions
        allowLoginUI:YES
        completionHandler:^(FBSession *session, FBSessionState state, NSError *error) {
          NSLOG(@"{facebook} got response from initial login");
          [self onSessionStateChanged:session state:state error:error];
        }];
    } else {
      permissionsAllowed = NO;
      permissionsErrorMessage = @"You can only ask for read permissions initially";
    }
  }

  if (!permissionsAllowed) {
    [[PluginManager get]
      dispatchJSResponse:@{@"error":permissionsErrorMessage}
      withError:nil
      andRequestId:requestId];
    self.loginRequestId = nil;
  }
}

// There are native versions of the share and send message dialogs available to
// users who have the facebook application on their phone. Fall back to web
// dialogs if facebook is unavailable.
- (void) ui:(NSDictionary *)opts withRequestId:(NSNumber *)requestId {
  FBSession * session = FBSession.activeSession;

  // TODO native share and send dialogs
  // BOOL shouldShowWebDialog = YES;
  __block BOOL paramsOK = YES;

  // Create editable params from arguments
  NSMutableDictionary * params = [[opts objectForKey:@"params"] mutableCopy];

  // Dialog method
  NSString * method;

  if ([params objectForKey:@"method"]) {
    method = [params objectForKey:@"method"];
    [params removeObjectForKey:@"method"];
  } else {
    method = @"apprequests";
  }

  // Stringify nested objects in params
  NSMutableDictionary *dialogParams = [[NSMutableDictionary alloc] init];
  [opts enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
    if ([obj isKindOfClass:[NSString class]]) {
      dialogParams[key] = obj;
    } else {
      NSError *error;
      NSData *jsonData = [NSJSONSerialization
        dataWithJSONObject:obj
        options:0
        error:&error];
      if (!jsonData) {
        paramsOK = NO;
        // Error
        *stop = YES;
      }
      dialogParams[key] = [[NSString alloc]
        initWithData:jsonData
        encoding:NSUTF8StringEncoding];
    }
  }];

  if (!paramsOK) {
    [[PluginManager get]
      dispatchJSResponse:@{@"error": @"Error completing dialog"}
      withError:nil
      andRequestId:requestId];
  } else {

    // Each dialog uses the same handler
    FBWebDialogHandler handler = ^(FBWebDialogResult result, NSURL *resultURL, NSError *error) {
      NSDictionary * res;
      if (error) {
        // Dialog failed with error
        res = @{@"error": @"Error completing dialog"};
      } else {
        if (result == FBWebDialogResultDialogNotCompleted) {
          // User clicked the "x" icon to Cancel
          res = nil;
        } else {
          // Send the URL parameters back, for a requests dialog, the "request" parameter
          // will include the resulting request id. For a feed dialog, the "post_id"
          // parameter will include the resulting post id.
          res = @{@"urlResponse": resultURL.absoluteString};
        }
      }

      [[PluginManager get]
       dispatchJSResponse:res
       withError:nil
       andRequestId:requestId];
    };

    // Special case app requests
    BOOL isApprequestsDialog = [method isEqualToString:@"apprequests"];
    NSString * title = dialogParams[@"title"];
    NSString * message = dialogParams[@"message"];

    // Show the dialog
    if (isApprequestsDialog && friendCache != NULL) {
      // Use friend cache
      [FBWebDialogs
        presentRequestsDialogModallyWithSession:session
        message:message
        title:title
        parameters:dialogParams
        handler:handler
        friendCache:friendCache];
    } else if (isApprequestsDialog) {
      // Request without friend cache
      [FBWebDialogs
        presentRequestsDialogModallyWithSession:session
        message:message
        title:title
        parameters:dialogParams
        handler:handler];
    } else {
      [FBWebDialogs
        presentDialogModallyWithSession:session
        dialog:method
        parameters:dialogParams
        handler:handler];
    }
  }
}

- (void) logout:(NSDictionary *)opts withRequestId:(NSNumber *)requestId {
  if (!FBSession.activeSession.isOpen) { return; }

  [FBSession.activeSession closeAndClearTokenInformation];

  [[PluginManager get]
    dispatchJSResponse: @{@"status": @"not_authorized"}
    withError:nil
    andRequestId:requestId];
}

- (void) api:(NSDictionary *)opts withRequestId:(NSNumber *)requestId {

  NSString * path = [opts valueForKey:@"path"];
  NSString * method = [[opts valueForKey:@"method"] uppercaseString];
  NSMutableDictionary * params = [[opts objectForKey:@"params"] mutableCopy];

  [FBRequestConnection
    startWithGraphPath:path
    parameters:params
    HTTPMethod:method
    completionHandler:^(FBRequestConnection *conn, id result, NSError * error) {
      // Result should be either an array or a dictionary
      NSDictionary * res;

      if (error) {
        res = [self getErrorResponse:error];
      } else if ([result isKindOfClass:[NSArray class]]) {
        // Array
        res = @{@"data": [result data]};
      } else {
        // dictionary
        res = (NSDictionary *) result;
      }

      [[PluginManager get]
        dispatchJSResponse:res
        withError:nil
        andRequestId:requestId];
    }];
}

- (void) getLoginStatus:(NSDictionary *)opts withRequestId:(NSNumber *)requestId {
  NSDictionary * loginStatus = [self authResponse];
  [[PluginManager get] dispatchJSResponse:loginStatus withError:nil andRequestId:requestId];
}

- (void) getAuthResponse:(NSDictionary *)opts withRequestId:(NSNumber *)requestId {
  NSDictionary * loginStatus = [self authResponse];
  NSDictionary * authResponse = [loginStatus objectForKey:@"authResponse"];
  [[PluginManager get] dispatchJSResponse:authResponse withError:nil andRequestId:requestId];
}

- (void) logEvent:(NSDictionary *)opts {
  NSLOG(@"{facebook} logEvent");
  NSString     * eventName  = opts[@"eventName"];
  NSNumber     * valueToSum = opts[@"valueToSum"];
  NSDictionary * parameters = opts[@"parameters"];
  if(valueToSum == [NSNull null]){ valueToSum = nil; }
  if(parameters == [NSNull null]){ parameters = nil; }
  [FBAppEvents logEvent:eventName valueToSum:[valueToSum doubleValue] parameters:parameters ];
}

- (void) logPurchase:(NSDictionary *)opts {
  NSLOG(@"{facebook} logPurchase");
  NSNumber     *purchaseAmount = opts[@"purchaseAmount"];
  NSString     *currency       = opts[@"currency"];
  NSDictionary *parameters     = opts[@"parameters"];
  if(parameters == [NSNull null]){ parameters = nil; }
  [FBAppEvents logPurchase:[purchaseAmount doubleValue] currency:currency parameters:parameters];
}

// -----------------------------------------------------------------------------
// HELPER FUNCTIONS
// -----------------------------------------------------------------------------

- (void) onSessionStateChanged:(FBSession *)session state:(FBSessionState) state error:(NSError *)error {
  NSLOG(@"{facebook} onSessionStateChanged");

  switch (state) {
    case FBSessionStateOpen:
    case FBSessionStateOpenTokenExtended:
      if (!error) {
        NSDictionary * res = [self authResponse];
        [[PluginManager get]
          dispatchEvent:@"auth.authResponseChanged"
          forPlugin:self
          withData:res];

        [[PluginManager get]
          dispatchEvent:@"auth.statusChange"
          forPlugin:self
          withData:res];

        if (self.loginRequestId != nil) {
          [[PluginManager get]
            dispatchJSResponse:res
            withError:nil
            andRequestId:self.loginRequestId];
          self.loginRequestId = nil;
        }
      }
      break;
    case FBSessionStateClosed:
      // TODO this should probably emit an auth.statusChange and/or
      // auth.authResponseChanged event.
    case FBSessionStateClosedLoginFailed:
      [FBSession.activeSession closeAndClearTokenInformation];
      break;
    default:
      break;
  }

  if (error) {
    NSDictionary * error_response = [self getErrorResponse:error];

    if (self.loginRequestId != nil) {
      [[PluginManager get]
        dispatchJSResponse:error_response
        withError:nil
        andRequestId:self.loginRequestId];
      self.loginRequestId = nil;
    }
  }
}

- (NSDictionary *) getErrorResponse:(NSError *) error {
  NSMutableDictionary * res = [[NSMutableDictionary alloc] init];
  res[@"error"] = [[error userInfo]
                   [@"com.facebook.sdk:ParsedJSONResponseKey"]
                   [@"body"]
                   [@"error"] mutableCopy];

  if ([FBErrorUtility shouldNotifyUserForError:error]) {
    res[@"error"][@"error_user_message"] = [FBErrorUtility userMessageForError:error];
    res[@"error"][@"error_user_title"] = [FBErrorUtility userTitleForError:error];
  }

  return res;
}

// Generate the auth response expected by javascript
- (NSDictionary *) authResponse {

  FBSession * session = FBSession.activeSession;
  FBAccessTokenData * tokenData = session.accessTokenData;

  NSTimeInterval expiresTimeInterval = [tokenData.expirationDate timeIntervalSinceNow];
  NSNumber* expiresIn = @0;
  if (expiresTimeInterval > 0) {
    expiresIn = [NSNumber numberWithDouble:expiresTimeInterval];
  }

  NSString * userID = @"";
  if (tokenData.userID != nil) {
    userID = tokenData.userID;
  }

  if (session.isOpen) {
    // Build an object that matches the javascript response
    NSDictionary * authData = @{
      @"accessToken": tokenData.accessToken,
      @"expiresIn": expiresIn,
      @"grantedScopes": [[tokenData permissions] componentsJoinedByString:@","],
      @"signedRequest": @"TODO",
      @"userID": userID
      };

    return @{
      @"status": @"connected",
      @"authResponse": authData
    };
  }

  return @{
    @"status": @"unknown"
  };
}

// Some helper functions for categorizing facebook permissions. The javascript
// `login` api is overloaded for initial login and subsequent permission
// requests. Native FB requires initial login to only request read permissions,
// and subsequent permission upgrades require separating read and publish calls

- (BOOL) isPublishPermission:(NSString*)permission {
    return [permission hasPrefix:@"publish"] ||
    [permission hasPrefix:@"manage"] ||
    [permission isEqualToString:@"ads_management"] ||
    [permission isEqualToString:@"create_event"] ||
    [permission isEqualToString:@"rsvp_event"];
}

- (BOOL) areAllPermissionsReadPermissions:(NSArray*)permissions {
    for (NSString *permission in permissions) {
        if ([self isPublishPermission:permission]) {
            return NO;
        }
    }
    return YES;
}

// -----------------------------------------------------------------------------
// GC PLUGIN INTERFACE
// -----------------------------------------------------------------------------

- (void) initializeWithManifest:(NSDictionary *)manifest appDelegate:(TeaLeafAppDelegate *)appDelegate {
  NSLOG(@"{facebook} sending plugin ready event");
  [[PluginManager get] dispatchEvent:@"FacebookPluginReady"
                           forPlugin:self
                           withData:@{@"status": @"OK"}];
}

- (void) applicationWillTerminate:(UIApplication *)app {
  @try {
    if (FBSession.activeSession != nil) {
      [FBSession.activeSession close];
    }
  }
  @catch (NSException *exception) {
    NSLOG(@"{facebook} Exception while processing terminate event: %@", exception);
  }
}

- (void) applicationDidBecomeActive:(UIApplication *)app {
  @try {
    // Track app active event with Facebook app analytics
    [FBAppEvents activateApp];
    [FBAppCall handleDidBecomeActive];
  }
  @catch (NSException *exception) {
    NSLOG(@"{facebook} Exception while processing active event: %@", exception);
  }
}

- (void) handleOpenURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication {
  NSLOG(@"{facebook} handleOpenURL: %@", url);
  @try {
    BOOL isFBCallback = [url.scheme hasPrefix:@"fb"];
    if (isFBCallback) {
      [FBAppCall handleOpenURL:url sourceApplication:sourceApplication];
    }
  }
  @catch (NSException *exception) {
    NSLOG(@"{facebook} Exception while processing openurl event: %@", exception);
  }
}

// The plugin must call super dealloc.
- (void) dealloc {
  [super dealloc];
}

// The plugin must call super init.
- (id) init {
  self = [super init];
  if (!self) {
    return nil;
  }

  return self;
}


@end





