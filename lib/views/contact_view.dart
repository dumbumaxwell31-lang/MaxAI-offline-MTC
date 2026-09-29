import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class ContactView extends StatelessWidget {
  const ContactView({super.key});

  static const _phoneNumber = '+263 781 485 580';
  static const _emailAddress = 'dumbumaxwell31@gmail.com';

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = Theme.of(context).hintColor;

    return Scaffold(
      backgroundColor: isDark ? Colors.black : Colors.white,
      appBar: AppBar(
        backgroundColor: isDark ? Colors.black : Colors.white,
        title: Text(
          'Contact Us',
          style: GoogleFonts.inter(fontSize: 24, fontWeight: FontWeight.w700),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
        children: [
          Text(
            'Get in touch',
            style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            'Contact Maxwell Dumbu at Mkoba Teachers College.',
            style: GoogleFonts.inter(fontSize: 14, color: muted),
          ),
          const SizedBox(height: 20),
          Container(
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                const _ContactMethod(
                  icon: Icons.chat_bubble_outline_rounded,
                  label: 'WhatsApp',
                  value: _phoneNumber,
                ),
                Divider(
                    height: 1,
                    indent: 56,
                    color: Theme.of(context).dividerColor),
                const _ContactMethod(
                  icon: Icons.call_outlined,
                  label: 'Calls',
                  value: _phoneNumber,
                ),
                Divider(
                    height: 1,
                    indent: 56,
                    color: Theme.of(context).dividerColor),
                const _ContactMethod(
                  icon: Icons.email_outlined,
                  label: 'Email',
                  value: _emailAddress,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ContactMethod extends StatelessWidget {
  const _ContactMethod({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).hintColor;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(icon, size: 21, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: GoogleFonts.inter(fontSize: 14, color: muted),
                ),
                const SizedBox(height: 3),
                SelectableText(
                  value,
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
