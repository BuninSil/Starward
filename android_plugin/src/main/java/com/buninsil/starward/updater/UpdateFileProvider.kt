package com.buninsil.starward.updater

import androidx.core.content.FileProvider

/** Distinct class name so the manifest merger keeps it apart from Godot's own FileProvider. */
class UpdateFileProvider : FileProvider()
