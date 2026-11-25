import Foundation
import MeetSolver
import MountainCore
import PowderMeetAPI

/// What the user can do about a failure.
public enum Recovery: String, Sendable, Hashable {
    case retry, signIn, openSettings, pickResort, none
}

public enum AuthFailure: Sendable, Hashable {
    case signedOut, sessionExpired, appleSignInFailed
    // Email accounts.
    case wrongPassword, emailNotConfirmed, emailInUse, weakPassword, invalidEmail
    case linkExpired, emailSignInUnavailable, tooManyEmails
}

/// A display name the server refused (`profile_update`).
public enum ProfileFailure: Sendable, Hashable {
    case nameTaken, nameNotAllowed, nameInvalid
}

/// Search by name, reports and the profile photo.
public enum SocialFailure: Sendable, Hashable {
    /// Too many searches or reports in a short time.
    case tooManyTries
    /// A photo the phone could not read or turn into a profile photo.
    case photoUnreadable
}

public enum NetworkFailure: Sendable, Hashable {
    case offline, timeout, server(status: Int), decoding
}

public enum DataFailure: Sendable, Hashable {
    case bundleUnavailable(resortID: String)
    case bundleCorrupt(BundleID)
    case statusUnavailable
    /// The `.powdermeet` backup could not be put together.
    case backupFailed
    /// Settings → Maps: a resort's map and imagery did not finish downloading.
    case mapNotDownloaded(resortID: String)
    /// Settings → Maps: a map could not be deleted from the phone.
    case mapNotRemoved(resortID: String)
    /// The phone has no room left for a map.
    case phoneFull
    /// Apple Health did not answer a read (locked phone, a busy store); not a refusal.
    case healthUnreadable
    /// A deleted account's recording could not be removed from the phone.
    case recordingNotRemoved
}

public enum MeetFailure: Sendable, Hashable {
    case notFriends, blocked, partnerBusy, meetGone, alreadyActive
    /// The server refused for another reason; the associated value is its code.
    case rejected(reason: String)
}

public enum PermissionFailure: Sendable, Hashable {
    case location, notifications, motion, health
}

/// Who a meet's failed solve is about, so its words can name them.
public struct MeetParty: Sendable, Hashable {
    /// The solver named this phone's skier; otherwise it named the partner.
    public var isYou: Bool
    public var partnerName: String

    public init(isYou: Bool, partnerName: String) {
        self.isYou = isYou
        self.partnerName = partnerName
    }
}

/// Every failure a user-started action can end in (`specs/01-ARCHITECTURE.md`
/// section 6). Each case carries its own wording and recovery.
public enum PowderMeetError: Error, Sendable, Hashable {
    case auth(AuthFailure)
    case network(NetworkFailure)
    case data(DataFailure)
    case routing(SolveFailure)
    /// A meet's solve that failed because of one of the two skiers, named.
    case meetRouting(SolveFailure, MeetParty)
    case meet(MeetFailure)
    case permission(PermissionFailure)
    case profile(ProfileFailure)
    case social(SocialFailure)

    public var userMessage: String {
        switch self {
        case .auth(.signedOut): "You're signed out."
        case .auth(.sessionExpired): "Your session expired. Sign in again to continue."
        case .auth(.appleSignInFailed): "Sign in with Apple didn't finish. Try again."
        case .auth(.wrongPassword): "That email and password don't match."
        case .auth(.emailNotConfirmed): "Confirm your email first: open the link we sent you, then sign in."
        case .auth(.emailInUse): "There's already an account with this email. Sign in instead."
        case .auth(.weakPassword): "Choose a stronger password: at least 8 characters."
        case .auth(.invalidEmail): "That doesn't look like an email address."
        case .auth(.linkExpired): "That link has expired or was already used. Ask for a new one."
        case .auth(.emailSignInUnavailable): "Email sign-in isn't available yet. Use Sign in with Apple."
        case .auth(.tooManyEmails): "Too many emails sent. Wait a few minutes and try again."
        case .profile(.nameTaken): "That name is taken. Try another."
        case .profile(.nameNotAllowed): "That name isn't allowed. Pick another."
        case .profile(.nameInvalid): "Names are 2 to 24 characters."
        case .social(.tooManyTries): "Too many tries. Wait a while and try again."
        case .social(.photoUnreadable): "That photo couldn't be used. Try another one."
        case .network(.offline): "No connection. This will work again once you have a signal."
        case .network(.timeout): "That took too long. Check your signal and try again."
        // A rate limit (`BackendError.rateLimited`): nothing is wrong, the user only has to wait.
        case .network(.server(status: 429)): "Too many tries. Wait a while and try again."
        case .network(.server):"PowderMeet is having trouble right now. Try again in a moment."
        case .network(.decoding): "PowderMeet sent something this version can't read. Update the app."
        case .data(.bundleUnavailable): "This resort's map couldn't be downloaded."
        case .data(.bundleCorrupt): "This resort's map didn't pass its check. Try again, or pick another resort."
        case .data(.statusUnavailable): "Live lift and trail status isn't available. Times use scheduled hours."
        case .data(.backupFailed): "The backup couldn't be made. Try again."
        case .data(.mapNotDownloaded): "The map didn't finish downloading. Try again."
        case .data(.mapNotRemoved): "The map couldn't be removed. Try again."
        case .data(.phoneFull): "There isn't enough space on this phone for this map."
        case .data(.healthUnreadable): "Apple Health didn't answer. Unlock your phone and try again."
        case .data(.recordingNotRemoved): "Your account is deleted, but its recording couldn't be cleared from this phone. Deleting the app removes it."
        case .routing(.originNotOnGraph): "We can't place both of you on the mountain yet. Wait for a better GPS fix."
        case .routing(.noRendezvousReachable): "There's no meeting point both of you can reach right now."
        case .routing(.statusExpired): "Lift status is out of date, so a route can't be trusted yet."
        case .routing(.bundleUnusable): "This resort's map can't be used for routing. Try reloading it."
        case .routing(.abilityBlocksAll): "Every route crosses terrain above someone's limit."
        case .routing(.liftDeadlineRisk): "The only way there depends on a lift that's about to close."
        case .routing(.lostAll): "No route could be found."
        case .meetRouting(let failure, let party): Self.named(failure, party)
        case .meet(.notFriends): "You can only meet up with friends."
        // Only an older server says `blocked`; a block is never revealed.
        case .meet(.blocked): "Couldn't send the request."
        case .meet(.partnerBusy): "Your friend is already in a meet."
        case .meet(.meetGone): "This meet is no longer open."
        case .meet(.alreadyActive): "You're already in a meet. End it before starting another."
        case .meet(.rejected): "That didn't go through. Try again."
        case .permission(.location): "PowderMeet needs your location to route you and share where you are."
        case .permission(.notifications): "Turn on notifications to hear about meet requests."
        case .permission(.motion): "Motion access improves run tracking."
        case .permission(.health): "Apple Health isn't available, or PowderMeet can't read workouts. Allow it in Settings → Health → Data Access & Devices."
        }
    }

    public var recovery: Recovery {
        switch self {
        case .auth: .signIn
        case .network(.decoding): .none
        case .network: .retry
        case .data(.bundleUnavailable): .retry
        case .data(.bundleCorrupt): .pickResort
        case .data(.statusUnavailable): .none
        case .data(.backupFailed): .retry
        case .data(.mapNotDownloaded), .data(.mapNotRemoved): .retry
        case .data(.phoneFull): .none
        case .data(.healthUnreadable): .retry
        case .data(.recordingNotRemoved): .none
        case .routing(.originNotOnGraph), .routing(.statusExpired), .routing(.lostAll): .retry
        case .routing(.bundleUnusable): .pickResort
        case .routing, .meetRouting: .none
        case .meet(.rejected): .retry
        case .meet: .none
        case .permission: .openSettings
        case .profile: .none
        case .social: .none
        }
    }

    /// A meet's failed solve, naming the skier it is about when the solver
    /// says who and the partner's name is known.
    public static func routing(_ failure: SolveFailure, me: UUID, partnerName: String?) -> PowderMeetError {
        guard let partnerName, !partnerName.isEmpty else { return .routing(failure) }
        switch failure {
        case .abilityBlocksAll(let skier), .noRendezvousReachable(let skier):
            return .meetRouting(failure, MeetParty(isYou: skier == me, partnerName: partnerName))
        default:
            return .routing(failure)
        }
    }

    /// For `noRendezvousReachable` the solver names the partner only when they
    /// reach no stop at all. It names this phone's skier both when they reach
    /// none and when the two reach none in common, so that case names both.
    private static func named(_ failure: SolveFailure, _ party: MeetParty) -> String {
        let name = party.partnerName
        switch failure {
        case .abilityBlocksAll:
            return party.isYou
                ? "You can't get down from here on runs within your limits."
                : "\(name) can't get down from where they are on runs within their limits."
        case .noRendezvousReachable:
            return party.isYou
                ? "There's nowhere you and \(name) can both reach right now."
                : "\(name) can't reach any meeting point from where they are right now."
        default:
            return PowderMeetError.routing(failure).userMessage
        }
    }

    /// True when waiting and trying the same thing again may work.
    public var isTransient: Bool {
        switch self {
        case .network(.offline), .network(.timeout): true
        case .network(.server(let status)): status >= 500 || status == 429
        default: false
        }
    }

    /// The typed error for anything a backend call can throw.
    public init(_ error: any Error) {
        switch error {
        case let error as PowderMeetError:
            self = error
        case let error as BackendError:
            self = switch error {
            case .notAuthenticated: .auth(.sessionExpired)
            case .signInFailed: .auth(.appleSignInFailed)
            case .offline: .network(.offline)
            case .timeout: .network(.timeout)
            case .server(let status, _): .network(.server(status: status))
            case .rateLimited: .network(.server(status: 429))
            case .decoding: .network(.decoding)
            case .notFriends: .meet(.notFriends)
            case .blocked: .meet(.blocked)
            case .meetBusyInvitee: .meet(.partnerBusy)
            case .meetBusyProposer: .meet(.alreadyActive)
            case .meetNotProposed, .meetExpired: .meet(.meetGone)
            case .invalid: .meet(.rejected(reason: "invalid"))
            case .notFound: .meet(.rejected(reason: "not_found"))
            case .resortNotPublished: .meet(.rejected(reason: "resort_not_published"))
            case .rendezvousUnknown: .meet(.rejected(reason: "rendezvous_unknown"))
            case .meetIDTaken: .meet(.rejected(reason: "meet_id_taken"))
            case .notParticipant: .meet(.rejected(reason: "not_participant"))
            case .invalidReason: .meet(.rejected(reason: "invalid_reason"))
            case .invalidState: .meet(.rejected(reason: "invalid_state"))
            case .nameTaken: .profile(.nameTaken)
            case .nameNotAllowed: .profile(.nameNotAllowed)
            case .invalidCredentials: .auth(.wrongPassword)
            case .emailNotConfirmed: .auth(.emailNotConfirmed)
            case .emailInUse: .auth(.emailInUse)
            case .weakPassword: .auth(.weakPassword)
            case .invalidEmail: .auth(.invalidEmail)
            case .linkExpired: .auth(.linkExpired)
            case .emailSignInDisabled: .auth(.emailSignInUnavailable)
            }
        case is DecodingError:
            self = .network(.decoding)
        case is CancellationError:
            // Only reached when a cancelled call's result is still looked at.
            self = .network(.timeout)
        default:
            self = .network(.server(status: 0))
        }
    }
}
