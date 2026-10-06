import 'package:flutter/material.dart';

import '../models.dart';
import 'auth_state.dart';

/// A prebuilt user/profile button, bound to an [AtlasAuthState].
///
/// It shows the signed-in user's avatar and name and a popup menu with a
/// "Sign out" action (plus an optional "Manage account"). It rebuilds itself as
/// the [session] changes — sign-in, sign-out, profile edits — because it listens
/// to the [AtlasAuthState] notifier. When signed out it renders [signedOut] (a
/// "Sign in" affordance by default).
///
/// `UserButton` is an alias, matching the Swift/Kotlin peers.
class AtlasUserButton extends StatelessWidget {
  const AtlasUserButton({
    super.key,
    required this.session,
    this.onManageAccount,
    this.onSignedOut,
    this.signedOut,
  });

  final AtlasAuthState session;

  /// Called when "Manage account" is chosen; the item is hidden when null.
  final VoidCallback? onManageAccount;

  /// Called after a successful sign-out.
  final VoidCallback? onSignedOut;

  /// What to show when signed out. Defaults to a disabled "Sign in" chip.
  final Widget? signedOut;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final user = session.user;
        if (user == null) {
          return signedOut ?? const _SignedOutChip();
        }
        return PopupMenuButton<String>(
          key: const Key('atlas.user_button'),
          tooltip: _displayName(user),
          onSelected: (value) async {
            if (value == 'signout') {
              await session.signOut();
              onSignedOut?.call();
            } else if (value == 'manage') {
              onManageAccount?.call();
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem<String>(
              enabled: false,
              child: _Identity(user),
            ),
            const PopupMenuDivider(),
            if (onManageAccount != null)
              const PopupMenuItem<String>(
                value: 'manage',
                child: Text('Manage account'),
              ),
            const PopupMenuItem<String>(
              value: 'signout',
              child: Text('Sign out'),
            ),
          ],
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: _Avatar(user),
          ),
        );
      },
    );
  }
}

/// Alias matching the Swift/Kotlin peers' `UserButton`.
typedef UserButton = AtlasUserButton;

String _displayName(AtlasUser user) {
  final name = [user.firstName, user.lastName]
      .where((p) => p != null && p.isNotEmpty)
      .join(' ');
  if (name.isNotEmpty) return name;
  return user.username ?? user.id;
}

String _initials(AtlasUser user) {
  final first = (user.firstName ?? '').trim();
  final last = (user.lastName ?? '').trim();
  if (first.isNotEmpty && last.isNotEmpty) {
    return '${first[0]}${last[0]}'.toUpperCase();
  }
  final single = first.isNotEmpty ? first : (user.username ?? user.id);
  return single.isNotEmpty ? single[0].toUpperCase() : '?';
}

class _Avatar extends StatelessWidget {
  const _Avatar(this.user);
  final AtlasUser user;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = user.imageUrl;
    return CircleAvatar(
      radius: 16,
      backgroundColor: scheme.primaryContainer,
      foregroundImage: (url != null && url.isNotEmpty) ? NetworkImage(url) : null,
      child: Text(
        _initials(user),
        style: TextStyle(color: scheme.onPrimaryContainer, fontSize: 13),
      ),
    );
  }
}

class _Identity extends StatelessWidget {
  const _Identity(this.user);
  final AtlasUser user;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryEmail = user.emailAddresses
        ?.where((e) => e.primary)
        .map((e) => e.emailAddress)
        .cast<String?>()
        .firstWhere((_) => true, orElse: () => null);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Avatar(user),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_displayName(user), style: theme.textTheme.titleSmall),
            if (primaryEmail != null)
              Text(primaryEmail, style: theme.textTheme.bodySmall),
          ],
        ),
      ],
    );
  }
}

class _SignedOutChip extends StatelessWidget {
  const _SignedOutChip();

  @override
  Widget build(BuildContext context) {
    return const Chip(
      key: Key('atlas.signed_out'),
      avatar: Icon(Icons.person_outline, size: 18),
      label: Text('Signed out'),
    );
  }
}
