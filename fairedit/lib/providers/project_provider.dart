import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/project.dart';
import '../services/project_service.dart';

class ProjectProvider extends ChangeNotifier {
  final ProjectService _service = ProjectService();
  List<EditProject> _projects = [];

  List<EditProject> get projects => _projects;

  Future<void> loadProjects() async {
    _projects = await _service.loadAll();
    notifyListeners();
  }

  Future<EditProject> createProject(File sourceImage) async {
    final project = await _service.create(sourceImage);
    _projects = [project, ..._projects];
    notifyListeners();
    return project;
  }
}
