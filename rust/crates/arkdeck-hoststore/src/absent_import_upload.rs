//! The Import owner on Windows, as a type with no value (TASK-XPA-005).
//!
//! The Job planner reads Import inputs through `ImportUploadStore`
//! (`import_upload.rs`), whose publication needs the Artifact publication
//! and Flash archive owners, which are not built on Windows yet. Until they
//! are, the planner is the same code with `imports: None`: a request naming
//! an Import input is refused as macOS refuses it without an Import owner.
//! No value of these types exists, so their methods are never called.
use crate::ArtifactReadStore;
use crate::artifact_read_owner::LeasedArtifact;
use crate::job_owner::import_references::ImportReference;
use arkdeck_contract::WireError;

/// The Import owner, not composed on Windows yet.
pub enum ImportUploadStore {}

/// An Import input's hold, which only an Import owner hands out.
pub(crate) enum ImportUse<'a> {
    #[allow(dead_code)]
    Never(std::convert::Infallible, std::marker::PhantomData<&'a ()>),
}

impl ImportUploadStore {
    pub(crate) fn acquire_inputs<'a>(
        &'a self,
        _artifacts: &ArtifactReadStore,
        _references: &[ImportReference],
    ) -> Result<Option<ImportUse<'a>>, WireError> {
        match *self {}
    }

    pub(crate) fn resolve_input(
        &self,
        _artifacts: &ArtifactReadStore,
        _reference: &ImportReference,
    ) -> Result<LeasedArtifact, WireError> {
        match *self {}
    }
}
