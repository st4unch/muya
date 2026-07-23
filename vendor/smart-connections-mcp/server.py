#!/usr/bin/env python3
"""
Smart Connections MCP Server
Exposes Smart Connections vector database to Claude Code via MCP protocol
"""

import asyncio
import os
from pathlib import Path
from typing import List, Dict
import numpy as np
from sentence_transformers import SentenceTransformer

from mcp.server.models import InitializationOptions
import mcp.types as types
from mcp.server import Server
from mcp.server.stdio import stdio_server


class SmartConnectionsDatabase:
    """Interface to Smart Connections .smart-env vector database"""

    def __init__(self, vault_path: str):
        self.vault_path = Path(vault_path)
        self.smart_env_path = self.vault_path / ".smart-env"
        self.multi_path = self.smart_env_path / "multi"

        # Lazy load embedding model (same as Smart Connections uses)
        self.model = None
        self.model_name = 'TaylorAI/bge-micro-v2'

        # Cache for embeddings
        self.embeddings_cache: Dict[str, Dict] = {}
        self.embeddings_loaded = False  # Lazy loading flag

    def ensure_model_loaded(self):
        """Lazy load the embedding model on first use"""
        if self.model is None:
            self.model = SentenceTransformer(self.model_name)

    def load_embeddings(self):
        """Load all .ajson embedding files (lazy loading)"""
        if self.embeddings_loaded:
            return  # Already loaded

        if not self.multi_path.exists():
            return

        count = 0
        for ajson_file in self.multi_path.glob("*.ajson"):
            try:
                import json
                with open(ajson_file, 'r', encoding='utf-8') as f:
                    content = f.read().strip()

                    # .ajson files are formatted as:
                    # "key1": {value1},
                    # "key2": {value2},
                    # We need to wrap in braces and remove trailing comma
                    if content and not content.startswith('{'):
                        # Remove trailing comma and wrap in braces
                        content = '{' + content.rstrip(',').strip() + '}'

                    # Parse the JSON structure
                    data = json.loads(content)

                    for key, item in data.items():
                        if 'embeddings' in item and 'TaylorAI/bge-micro-v2' in item['embeddings']:
                            vec = item['embeddings']['TaylorAI/bge-micro-v2']['vec']

                            # Store in cache
                            self.embeddings_cache[key] = {
                                'path': item.get('path'),
                                'vector': np.array(vec, dtype=np.float32),
                                'text': item.get('text', ''),
                                'key': key,
                                'lines': item.get('lines', []),
                                'metadata': item.get('metadata', {})
                            }
                            count += 1
            except Exception as e:
                # Skip malformed files
                continue

        self.embeddings_loaded = True

    def semantic_search(self, query: str, limit: int = 10, min_similarity: float = 0.3) -> List[Dict]:
        """
        Perform semantic search against the vector database

        Args:
            query: Natural language query
            limit: Maximum number of results
            min_similarity: Minimum cosine similarity threshold (0-1)

        Returns:
            List of results with path, score, and metadata
        """
        # Lazy load model and embeddings on first use
        self.ensure_model_loaded()
        self.load_embeddings()

        # Encode query
        query_vec = self.model.encode(query)
        query_vec = query_vec / np.linalg.norm(query_vec)  # Normalize

        # Compute similarities
        results = []
        for key, item in self.embeddings_cache.items():
            vec = item['vector']
            vec = vec / np.linalg.norm(vec)  # Normalize

            # Cosine similarity
            similarity = float(np.dot(query_vec, vec))

            if similarity >= min_similarity:
                results.append({
                    'key': key,
                    'path': item['path'],
                    'similarity': similarity,
                    'lines': item.get('lines'),
                    'metadata': item.get('metadata', {}),
                    'text_preview': item.get('text', '')[:200] if item.get('text') else ''
                })

        # Sort by similarity descending
        results.sort(key=lambda x: x['similarity'], reverse=True)

        return results[:limit]

    def find_related(self, file_path: str, limit: int = 10) -> List[Dict]:
        """
        Find notes related to a specific file

        Args:
            file_path: Path to file (relative to vault)
            limit: Maximum number of results

        Returns:
            List of related files
        """
        # Lazy load embeddings on first use
        self.load_embeddings()

        # Find the embedding for this file
        target_key = f"smart_sources:{file_path}"

        if target_key not in self.embeddings_cache:
            return []

        target_vec = self.embeddings_cache[target_key]['vector']
        target_vec = target_vec / np.linalg.norm(target_vec)

        # Find similar
        results = []
        for key, item in self.embeddings_cache.items():
            if key == target_key:
                continue  # Skip self

            # Only compare to other sources, not blocks
            if not key.startswith('smart_sources:'):
                continue

            vec = item['vector']
            vec = vec / np.linalg.norm(vec)

            similarity = float(np.dot(target_vec, vec))

            results.append({
                'key': key,
                'path': item['path'],
                'similarity': similarity,
                'metadata': item.get('metadata', {})
            })

        results.sort(key=lambda x: x['similarity'], reverse=True)
        return results[:limit]

    def _path_from_key(self, key: str) -> str | None:
        """Extract file path from a smart_blocks/smart_sources key."""
        for prefix in ('smart_blocks:', 'smart_sources:'):
            if key.startswith(prefix):
                rest = key[len(prefix):]
                return rest.split('#')[0]
        return None

    def _read_lines(self, rel_path: str, lines: list | None) -> str:
        """Read text from vault file given relative path and line range."""
        if not rel_path or not lines or len(lines) < 2:
            return ''
        fpath = self.vault_path / rel_path
        if not fpath.exists():
            return ''
        try:
            all_lines = fpath.read_text(encoding='utf-8', errors='replace').splitlines()
            start = max(0, lines[0] - 1)
            end = min(len(all_lines), lines[1])
            return '\n'.join(all_lines[start:end])
        except Exception:
            return ''

    def get_context_blocks(self, query: str, max_blocks: int = 5) -> List[Dict]:
        """
        Get best context blocks for a query (for RAG)

        Args:
            query: Query string
            max_blocks: Maximum number of blocks to return

        Returns:
            List of block contents with metadata
        """
        self.ensure_model_loaded()
        self.load_embeddings()

        query_vec = self.model.encode(query)
        query_vec = query_vec / np.linalg.norm(query_vec)

        results = []
        for key, item in self.embeddings_cache.items():
            if not key.startswith('smart_blocks:'):
                continue

            vec = item['vector']
            vec = vec / np.linalg.norm(vec)

            similarity = float(np.dot(query_vec, vec))

            if similarity > 0.4:
                rel_path = item.get('path') or self._path_from_key(key)
                lines = item.get('lines')
                text = item.get('text') or self._read_lines(rel_path, lines)
                lines_str = f"{lines[0]}-{lines[1]}" if lines and len(lines) >= 2 else None

                results.append({
                    'key': key,
                    'path': rel_path,
                    'similarity': similarity,
                    'lines': lines_str,
                    'text': text
                })

        results.sort(key=lambda x: x['similarity'], reverse=True)
        return results[:max_blocks]


async def main():
    import sys
    import logging

    # Setup logging to stderr
    logging.basicConfig(level=logging.DEBUG, stream=sys.stderr, format='%(asctime)s - %(levelname)s - %(message)s')
    logger = logging.getLogger(__name__)

    logger.debug("Starting smart-connections-mcp server...")

    # Get vault path from environment
    vault_path = os.getenv('OBSIDIAN_VAULT_PATH')
    if not vault_path:
        raise ValueError("OBSIDIAN_VAULT_PATH environment variable not set")

    logger.debug(f"Vault path: {vault_path}")

    # Initialize database
    db = SmartConnectionsDatabase(vault_path)
    logger.debug("Database initialized")

    # Create MCP server
    server = Server("smart-connections-mcp")
    logger.debug("MCP server created")

    @server.list_tools()
    async def handle_list_tools() -> list[types.Tool]:
        """List available tools"""
        return [
            types.Tool(
                name="semantic_search",
                description="Search vault using semantic similarity (not keyword matching). Finds notes related to query meaning, not just exact words.",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "query": {
                            "type": "string",
                            "description": "Natural language query describing what to search for"
                        },
                        "limit": {
                            "type": "integer",
                            "description": "Maximum number of results (default: 10)",
                            "default": 10
                        },
                        "min_similarity": {
                            "type": "number",
                            "description": "Minimum similarity threshold 0-1 (default: 0.3)",
                            "default": 0.3
                        }
                    },
                    "required": ["query"]
                }
            ),
            types.Tool(
                name="find_related",
                description="Find notes related to a specific file path. Like Smart Connections sidebar in Obsidian.",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "file_path": {
                            "type": "string",
                            "description": "File path relative to vault root (e.g., 'DailyNotes/2025-10-25.md')"
                        },
                        "limit": {
                            "type": "integer",
                            "description": "Maximum number of results (default: 10)",
                            "default": 10
                        }
                    },
                    "required": ["file_path"]
                }
            ),
            types.Tool(
                name="get_context_blocks",
                description="Get best text blocks for a query (for RAG/context building). Returns actual text content.",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "query": {
                            "type": "string",
                            "description": "Query to find relevant context for"
                        },
                        "max_blocks": {
                            "type": "integer",
                            "description": "Maximum number of blocks (default: 5)",
                            "default": 5
                        }
                    },
                    "required": ["query"]
                }
            )
        ]

    @server.call_tool()
    async def handle_call_tool(
        name: str, arguments: dict | None
    ) -> list[types.TextContent | types.ImageContent | types.EmbeddedResource]:
        """Handle tool execution requests"""
        import json

        if arguments is None:
            arguments = {}

        try:
            if name == "semantic_search":
                results = db.semantic_search(
                    query=arguments['query'],
                    limit=arguments.get('limit', 10),
                    min_similarity=arguments.get('min_similarity', 0.3)
                )

                return [
                    types.TextContent(
                        type="text",
                        text=json.dumps({
                            "query": arguments['query'],
                            "results_count": len(results),
                            "results": results
                        }, indent=2)
                    )
                ]

            elif name == "find_related":
                results = db.find_related(
                    file_path=arguments['file_path'],
                    limit=arguments.get('limit', 10)
                )

                return [
                    types.TextContent(
                        type="text",
                        text=json.dumps({
                            "source_file": arguments['file_path'],
                            "related_count": len(results),
                            "related_files": results
                        }, indent=2)
                    )
                ]

            elif name == "get_context_blocks":
                results = db.get_context_blocks(
                    query=arguments['query'],
                    max_blocks=arguments.get('max_blocks', 5)
                )

                return [
                    types.TextContent(
                        type="text",
                        text=json.dumps({
                            "query": arguments['query'],
                            "blocks_count": len(results),
                            "blocks": results
                        }, indent=2)
                    )
                ]

            else:
                raise ValueError(f"Unknown tool: {name}")

        except Exception as e:
            raise RuntimeError(f"Tool execution error: {str(e)}")

    # Run the server using stdin/stdout streams
    logger.debug("Starting stdio server...")
    async with stdio_server() as (read_stream, write_stream):
        logger.debug("stdio server started, running MCP server...")
        await server.run(
            read_stream,
            write_stream,
            InitializationOptions(
                server_name="smart-connections-mcp",
                server_version="0.1.0",
                capabilities=types.ServerCapabilities(
                    tools=types.ToolsCapability(),
                ),
            ),
        )
        logger.debug("MCP server finished")


if __name__ == "__main__":
    asyncio.run(main())
