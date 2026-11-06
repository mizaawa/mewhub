import 'package:flutter/material.dart';

import '../../data/defaults.dart';
import '../../core/i18n.dart';
import '../widgets/common.dart';

class UserProfileHeader extends StatelessWidget {
  const UserProfileHeader({super.key, required this.name, required this.avatar, required this.onTap});

  final String name;
  final String avatar;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final displayName = name.trim().isEmpty ? 'MewHub' : name.trim();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('user-profile-header'),
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ClipOval(
                      child: AvatarView(
                        value: avatar.isEmpty ? defaultAssistantAvatar : avatar,
                        fallback: displayName,
                        size: 58,
                      ),
                    ),
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: scheme.secondaryContainer,
                          shape: BoxShape.circle,
                          border: Border.all(color: scheme.surface, width: 2),
                        ),
                        child: Icon(Icons.edit_rounded, size: 12, color: scheme.onSecondaryContainer),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(Icons.edit_outlined, size: 17, color: scheme.onSurfaceVariant),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _greeting(),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return t('早上好 👋', 'Good morning 👋');
    if (hour < 18) return t('下午好 👋', 'Good afternoon 👋');
    return t('晚上好 👋', 'Good evening 👋');
  }
}
