import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/project.dart';

/// Reads and writes the local project index (`projects.json`) and copies
/// picked photos into the app's own documents directory so they survive
/// even if the user deletes the original from their gallery.
class ProjectService {
  static const _uuid = Uuid();

  Future<Directory> _projectsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'fairedit_projects'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _indexFile() async {
    final dir = await _projectsDir();
    return File(p.join(dir.path, 'projects.json'));
  }

  Future<List<EditProject>> loadAll() async {
    final file = await _indexFile();
    if (!await file.exists()) return [];
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    final projects = list
        .map((e) => EditProject.fromJson(e as Map<String, dynamic>))
        .toList();
    projects.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return projects;
  }

  Future<void> _saveAll(List<EditProject> projects) async {
    final file = await _indexFile();
    await file.writeAsString(
      jsonEncode(projects.map((e) => e.toJson()).toList()),
    );
  }

  Future<EditProject> create(File sourceImage) async {
    final dir = await _projectsDir();
    final id = _uuid.v4();
    final sourceExt = p.extension(sourceImage.path);
    final ext = sourceExt.isEmpty ? '.jpg' : sourceExt;

    final projectDir = Directory(p.join(dir.path, id));
    await projectDir.create(recursive: true);
    final destPath = p.join(projectDir.path, 'original$ext');
    await sourceImage.copy(destPath);

    final project = EditProject(
      id: id,
      name: 'Untitled ${DateTime.now().toString().substring(0, 16)}',
      imagePath: destPath,
      createdAt: DateTime.now(),
    );

    final all = await loadAll();
    all.insert(0, project);
    await _saveAll(all);
    return project;
  }
}
