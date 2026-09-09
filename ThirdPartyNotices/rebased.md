# IntelliJ / rebased graph layout

`Sources/GitStride/GraphLayout.swift` adapts the DFS layout-index assignment,
edge ordering and per-row print-element approach in DetachHead/rebased (IntelliJ):

- https://github.com/DetachHead/rebased/blob/master/platform/vcs-log/graph/src/com/intellij/vcs/log/graph/impl/permanent/GraphLayoutBuilder.kt
- https://github.com/DetachHead/rebased/blob/master/platform/vcs-log/graph/src/com/intellij/vcs/log/graph/impl/print/GraphElementComparatorByLayoutIndex.java
- https://github.com/DetachHead/rebased/blob/master/platform/vcs-log/graph/src/com/intellij/vcs/log/graph/impl/print/PrintElementGeneratorImpl.kt

Copyright 2000-2024 JetBrains s.r.o. and contributors. Licensed under the Apache
License, Version 2.0 (see Apache-2.0.txt).

The Swift adaptation adds partial-history handling, deterministic tie breaking,
cached row geometry, and integration with Twig's SwiftUI interface. The original
Java/Kotlin files are not bundled. The UI and Canvas renderer are implemented
for Twig, with reference to IntelliJ's compact rows and center-to-center edges.
