//! This module contains the [MerkleTree] struct and related types like the 
//! [MerkleProof].

use std::collections::HashMap;

use crate::merkle::{Digest, MerkleTreeNode};

use super::Int;

/// A leaf of a [MerkleTree], it contains the offset of the leaf in the tree, 
/// and the hash of the data.
#[derive(Clone, Debug)]
pub struct MerkleTreeLeaf {
    pub node: Digest,
    pub accumulated_count: Int,
    pub log2_size: Option<u64>,
}

/// A [MerkleProof] is used to verify that a leaf is part of a [MerkleTree].
pub type MerkleProof = Vec<Digest>;

struct ProofAccumulator {
    pub leaf: Digest,
    pub proof: MerkleProof,
}

impl Default for ProofAccumulator {
    fn default() -> Self {
        ProofAccumulator {
            leaf: Digest::zeroed(),
            proof: Vec::new(),
        }
    }
}

#[derive(Debug)]
pub struct MerkleTree {
    log2_size: u32,
    root: Digest,
    leafs: Vec<MerkleTreeLeaf>,
    nodes: HashMap<Digest, MerkleTreeNode>,
}

impl MerkleTree {
    pub fn new(
        log2_size: u32,
        root: Digest,
        leafs: Vec<MerkleTreeLeaf>,
        nodes: HashMap<Digest, MerkleTreeNode>,
    ) -> Self {
        MerkleTree {
            log2_size: log2_size,
            root: root,
            leafs: leafs,
            nodes: nodes,
        }
    }

    pub fn root_hash(&self) -> Digest {
        self.root
    }

    pub fn root_children(&self) -> (Digest, Digest) {
        self.node_children(self.root)
            .expect("root does not have children")
    }

    pub fn node_children(&self, digest: Digest) -> Option<(Digest, Digest)> {
        let node = self.nodes.get(&digest).expect("node does not exist");
        node.children()
    }

    pub fn prove_leaf(&self, index: u64) -> (Digest, MerkleProof) {
        let height = self.calculate_height();

        assert!((index >> height) == 0);

        let mut proof_acc = ProofAccumulator::default();

        self.proof(
            &mut proof_acc,
            self.nodes.get(&self.root).expect("root does not exist"),
            height,
            index,
        );

        (proof_acc.leaf, proof_acc.proof)
    }

    fn calculate_height(&self) -> u64 {
        let mut height = Int::BITS as u64;
        if let Some(leaf) = self.leafs.get(0) {
            if let Some(log2_size) = leaf.log2_size {
                height = log2_size + self.log2_size as u64;
            }
        }
        height
    }

    fn proof(
        &self,
        proof_acc: &mut ProofAccumulator,
        root: &MerkleTreeNode,
        height: u64,
        include_index: u64,
    ) {
        if height == 0 {
            proof_acc.leaf = root.digest;
            return;
        }

        let new_height = height - 1;
        let (left, right) = root.children().expect("root does not have children");
        let left = self.nodes.get(&left).expect("left child does not exist");
        let right = self.nodes.get(&right).expect("right child does not exist");

        if (include_index >> new_height) & 1 == 0 {
            let left = left;
            self.proof(proof_acc, left, new_height, include_index);
            proof_acc.proof.push(left.digest);
        } else {
            let right = right;
            self.proof(proof_acc, right, new_height, include_index);
            proof_acc.proof.push(right.digest);
        }
    }

    pub fn last(&self) -> (Digest, MerkleProof) {
        let mut proof = Vec::new();
        let mut children = Some(self.root_children());
        let mut old_right = self.root;

        while let Some((left, right)) = children {
            proof.push(left);
            old_right = right;
            children = self.node_children(right);
        }

        proof.reverse();

        (old_right, proof)
    }
}
