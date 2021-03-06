new_account = Account.find(8858)
old_account = Account.find(3380)

Document.duplicate(old_account.document_ids, new_account)

project_map = old_account.projects.each_with_object({}){ |project, map|
  map[project] = Project.create(project.attributes.except('id').merge({'account_id'=>new_account.id}))
}

# wait for duplication job to finish

# map the old document's to the new ones
documents_map = new_account.documents.each_with_object({}){|new_doc, map|
  if (old_doc = old_account.documents.where(title:new_doc.title, description:new_doc.description).first)
    map[new_doc] = old_doc
  end
}

documents_map.each{|old_doc, new_doc|
  old_doc.projects.each{|old_project|
    if (np = project_map[old_project])
      np.documents<<new_doc
    end
  }
}
