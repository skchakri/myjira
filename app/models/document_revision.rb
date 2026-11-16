# An earlier version of a Document, captured whenever its title or body changes.
class DocumentRevision < ApplicationRecord
  belongs_to :document
end
