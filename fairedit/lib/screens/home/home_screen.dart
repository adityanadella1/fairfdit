import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../models/project.dart';
import '../../providers/project_provider.dart';
import '../editor/editor_screen.dart';

/// The library. Lightroom's grid of edits, with the two things that grid
/// has to communicate: which photos you have, and which ones you have
/// already worked on.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ProjectProvider>().loadProjects();
    });
  }

  Future<void> _newProject() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 100,
      );
      if (picked == null || !mounted) return;
      final project =
          await context.read<ProjectProvider>().createProject(File(picked.path));
      if (!mounted) return;
      await _openProject(project);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _openProject(EditProject project) async {
    await Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: AppMotion.medium,
        reverseTransitionDuration: AppMotion.fast,
        pageBuilder: (_, __, ___) => EditorScreen(
          imagePath: project.imagePath,
          projectName: project.name,
        ),
        // A fade-through rather than a slide: the editor is the same photo
        // at a different scale, not a different place.
        transitionsBuilder: (_, animation, __, child) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween(begin: 0.97, end: 1.0).animate(
              CurvedAnimation(parent: animation, curve: AppMotion.emphasized),
            ),
            child: child,
          ),
        ),
      ),
    );
    // Edits are saved to disk when leaving the editor — re-read the
    // project list so this project's card picks up the latest preview.png.
    if (mounted) context.read<ProjectProvider>().loadProjects();
  }

  @override
  Widget build(BuildContext context) {
    final projects = context.watch<ProjectProvider>().projects;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _LibraryHeader(count: projects.length),
            Expanded(
              child: projects.isEmpty
                  ? _EmptyLibrary(onAdd: _newProject, busy: _picking)
                  : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 6,
                        crossAxisSpacing: 6,
                        childAspectRatio: 1,
                      ),
                      itemCount: projects.length,
                      itemBuilder: (context, index) => _ProjectTile(
                        project: projects[index],
                        onTap: () => _openProject(projects[index]),
                      ),
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: projects.isEmpty
          ? null
          : FloatingActionButton.extended(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              onPressed: _picking ? null : _newProject,
              icon: _picking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.add_photo_alternate_outlined, size: 20),
              label: const Text('Add photo'),
            ),
    );
  }
}

class _LibraryHeader extends StatelessWidget {
  final int count;

  const _LibraryHeader({required this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'FairEdit',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                count == 0
                    ? 'Your library'
                    : '$count ${count == 1 ? 'photo' : 'photos'}',
                style: AppText.hint,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProjectTile extends StatelessWidget {
  final EditProject project;
  final VoidCallback onTap;

  const _ProjectTile({required this.project, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final previewFile = File(project.previewPath);
    final hasPreview = previewFile.existsSync();
    final displayFile = hasPreview ? previewFile : File(project.imagePath);
    // Ties the widget's cache key to the file's last-modified time, so
    // Flutter's image cache doesn't keep showing a stale thumbnail after
    // preview.png is overwritten.
    final cacheKey = displayFile.existsSync()
        ? displayFile.lastModifiedSync().millisecondsSinceEpoch
        : 0;

    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppLayout.radiusSm),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: AppColors.surface),
            Image.file(
              displayFile,
              key: ValueKey('${displayFile.path}-$cacheKey'),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const Center(
                child: Icon(
                  Icons.broken_image_outlined,
                  color: AppColors.textTertiary,
                  size: 22,
                ),
              ),
            ),
            // An "edited" marker exists only once a preview has been
            // rendered, which only happens after the editor saves — so
            // the badge is an accurate signal, not a guess.
            if (hasPreview)
              Positioned(
                right: 5,
                bottom: 5,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Icon(
                    Icons.tune_rounded,
                    size: 11,
                    color: AppColors.accent,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  final VoidCallback onAdd;
  final bool busy;

  const _EmptyLibrary({required this.onAdd, required this.busy});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: const BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.photo_library_outlined,
                color: AppColors.textTertiary,
                size: 32,
              ),
            ),
            const SizedBox(height: 18),
            const Text('No photos yet', style: AppText.title),
            const SizedBox(height: 6),
            const Text(
              'Add a photo to start editing. Every change stays\nnon-destructive — your original is never touched.',
              style: AppText.hint,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: busy ? null : onAdd,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.add_photo_alternate_outlined, size: 18),
              label: const Text('Add photo'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                minimumSize: const Size(0, 44),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
